# frozen_string_literal: true

require_relative "../test_helper"
require "deadheat/engine"
require "deadheat/sweep/runner"
require "prism"
require "rack/mock"
require "tmpdir"

# The parts that keep Dead Heat from doing harm: where it will run, who can see its report, what it
# writes into files, and what it shows.
class DatabaseNameTest < Minitest::Test
  def test_only_a_name_with_test_as_a_word_passes
    %w[app_test app_test-2 storage/test.sqlite3 TEST_DB testing_db /srv/app/db/shop_test.sqlite3 db/test/primary.sqlite3].each do |name|
      assert Deadheat::Preflight.test_name?(name), name
    end
    assert Deadheat::Preflight.test_name?("MyAppTest")
    %w[contest_production latest attestations app_production app_development /srv/test/production.sqlite3 test_scores_production test_live
       /srv/test/app/storage/main.sqlite3 db/production/test_copy.sqlite3 storage/development.sqlite3].each do |name|
      refute Deadheat::Preflight.test_name?(name), name
    end
  end

  def test_a_name_that_also_names_another_environment_never_passes
    %w[AppTestProduction MyAppTestProd AppTestLive ab_test_development test_app_development app_test_dev app_test_preprod app_test_prd
       productiondb_test_production test/development.sqlite3 app_test_staging TestStage].each do |name|
      refute Deadheat::Preflight.test_name?(name), name
    end
    %w[devise_test developer_portal_test livestock_test backstage_test product_test].each do |name|
      assert Deadheat::Preflight.test_name?(name), "#{name} only contains such a word inside another"
    end
  end

  def test_every_database_the_app_writes_to_is_checked
    other = Struct.new(:database).new("legacy_reporting")
    error = assert_raises(Deadheat::Refused) { Deadheat::Preflight.check_database_name!(other) }
    assert_includes error.message, "legacy_reporting"
    ENV["DEADHEAT_ALLOW_DATABASE"] = "something_else,legacy_reporting"
    Deadheat::Preflight.check_database_name!(other)
    assert_respond_to Deadheat::Preflight.other_databases, :each
  ensure
    ENV.delete("DEADHEAT_ALLOW_DATABASE")
  end

  def test_a_race_test_checks_the_database_before_any_of_its_setup_runs
    env = Rails.env
    Rails.env = "development"
    error = assert_raises(Deadheat::Refused) { Deadheat::RaceTest.new("x").before_setup }
    assert_includes error.message, "test environment"
    refute Deadheat::DatabaseCleanerPause.paused?, "nothing else ran"
  ensure
    Rails.env = env
  end
end

class ReportAccessTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir
    @results_dir = Deadheat.config.results_dir
    Deadheat.config.results_dir = nil # the default: tmp/deadheat in the app
    @run = File.join(@root, "tmp/deadheat/runs/20260101-000000")
    FileUtils.mkdir_p(@run)
    File.write(File.join(@run, "one.json"), JSON.generate(name: "a race", tries: 20, counts: {}, findings: []))
    @outside = File.join(@root, "private")
    FileUtils.mkdir_p(@outside)
    File.write(File.join(@outside, "secret.json"), JSON.generate(name: "SECRET", findings: []))
  end

  def teardown
    Deadheat.config.results_dir = @results_dir
    FileUtils.rm_rf(@root)
  end

  def test_the_results_folder_can_be_moved
    elsewhere = File.join(@root, "elsewhere")
    FileUtils.mkdir_p(File.join(elsewhere, "runs/20260202-000000"))
    File.write(File.join(elsewhere, "runs/20260202-000000/one.json"), JSON.generate(name: "moved", findings: []))
    Deadheat.config.results_dir = elsewhere
    assert_equal "20260202-000000", Deadheat::Report.load(@root).id
  end

  def test_half_written_and_foreign_files_are_skipped
    File.write(File.join(@run, "broken.json"), "{ \"name\": ")
    File.write(File.join(@run, "list.json"), "[1, 2]")
    File.write(File.join(@run, "sweep.json"), "{")
    File.write(File.join(@root, "tmp/deadheat/scan.json"), "{}")
    run = Deadheat::Report.load(@root)
    assert_equal 1, run.results.size
    assert_empty run.suspects
    assert_includes Deadheat::Report.html(run), "Dead Heat"
  end

  def test_old_runs_are_pruned_but_nothing_else
    runs = File.join(@root, "tmp/deadheat/runs")
    5.times { |i|
      FileUtils.mkdir_p(File.join(runs, "2025010#{i}-000000"))
      File.write(File.join(runs, "2025010#{i}-000000/a.json"), "{}")
      FileUtils.touch(File.join(runs, "2025010#{i}-000000"), mtime: Time.now - 1000 + i) }
    FileUtils.mkdir_p(File.join(runs, "my-notes"))
    FileUtils.mkdir_p(File.join(runs, "20240101-000000"))
    File.write(File.join(runs, "20240101-000000/keep.txt"), "not ours")
    FileUtils.touch(File.join(runs, "20240101-000000"), mtime: Time.now - 5000)
    Deadheat::Results.prune(runs, keep: 3)
    left = Dir.children(runs).sort
    assert_includes left, "my-notes"
    assert_includes left, "20240101-000000", "a folder holding someone else's file is left alone"
    assert_equal 2, left.grep(/\A2025/).size
  end

  def test_a_run_is_loaded_by_its_folder_name
    assert_equal "20260101-000000", Deadheat::Report.load(@root).id
    assert_equal "20260101-000000", Deadheat::Report.load(@root, "20260101-000000").id
  end

  def test_an_id_can_never_point_outside_the_results_folder
    ["../../../private", "..", ".", "a/../../../private", "/etc", "..\\..\\private", ["20260101-000000"], { "a" => "b" }, ""].each do |id|
      assert_nil Deadheat::Report.load(@root, id), id.inspect
    end
  end

  # Replaces a method for the length of the block.
  def swap(object, name, value)
    original = object.method(name)
    object.define_singleton_method(name) { value }
    yield
  ensure
    object.define_singleton_method(name, original)
  end

  def get(path, headers = {})
    env = Rack::MockRequest.env_for(path, { "REMOTE_ADDR" => "127.0.0.1", "HTTP_HOST" => "localhost" }.merge(headers))
    status, response_headers, body = Deadheat::Engine.call(env)
    text = +""
    body.each { |part| text << part }
    [status, text, response_headers]
  end

  def test_the_dashboard_answers_only_this_computer
    swap(Rails, :root, Pathname.new(@root)) do
      status, text, headers = get("/")
      assert_equal 200, status
      assert_includes text, "Dead Heat"
      assert_equal "no-store", headers["cache-control"]
      assert_match(/default-src 'none'/, headers["content-security-policy"])

      assert_equal 403, get("/", "REMOTE_ADDR" => "203.0.113.9").first
      assert_equal 403, get("/", "HTTP_X_FORWARDED_FOR" => "203.0.113.9").first, "a local proxy passing on a remote visitor"
      assert_equal 403, get("/", "REMOTE_ADDR" => "203.0.113.9", "HTTP_X_FORWARDED_FOR" => "127.0.0.1").first
      assert_equal 403, get("/", "HTTP_X_FORWARDED_FOR" => "127.0.0.1, 10.0.0.5").first, "a private-network visitor behind a local proxy"
      assert_equal 403, get("/", "HTTP_HOST" => "evil.example.com").first, "another site's name pointed at this computer"
      assert_equal 200, get("/", "HTTP_X_FORWARDED_FOR" => "127.0.0.1").first, "a local proxy passing on a local visitor"
    end
  end

  def test_a_local_proxy_naming_a_remote_visitor_in_any_header_is_refused
    swap(Rails, :root, Pathname.new(@root)) do
      %w[HTTP_X_REAL_IP HTTP_CLIENT_IP HTTP_X_CLIENT_IP HTTP_TRUE_CLIENT_IP HTTP_CF_CONNECTING_IP].each do |header|
        assert_equal 403, get("/", header => "203.0.113.9").first, header
        assert_equal 200, get("/", header => "127.0.0.1").first, "#{header} naming this computer"
      end
      assert_equal 403, get("/", "HTTP_FORWARDED" => "for=127.0.0.1").first
      assert_equal 403, get("/", "HTTP_VIA" => "1.1 proxy").first
    end
  end

  def test_a_forged_forwarded_host_does_not_make_another_site_local
    swap(Rails, :root, Pathname.new(@root)) do
      assert_equal 403, get("/", "HTTP_HOST" => "evil.example.com", "HTTP_X_FORWARDED_HOST" => "localhost").first
      assert_equal 403, get("/", "HTTP_X_FORWARDED_HOST" => "evil.example.com").first
      assert_equal 403, get("/", "HTTP_X_FORWARDED_HOST" => "localhost, evil.example.com").first
      assert_equal 200, get("/", "HTTP_HOST" => "127.0.0.1:3000").first
      assert_equal 200, get("/", "HTTP_HOST" => "[::1]:3000", "REMOTE_ADDR" => "::1").first
      assert_equal 200, get("/", "HTTP_HOST" => "shop.localhost:3000").first
    end
  end

  def test_another_websites_script_cannot_read_the_page
    swap(Rails, :root, Pathname.new(@root)) do
      assert_equal 403, get("/", "HTTP_ORIGIN" => "https://evil.example.com").first
      assert_equal 403, get("/", "HTTP_ORIGIN" => "null").first
      assert_equal 403, get("/", "HTTP_SEC_FETCH_SITE" => "cross-site", "HTTP_SEC_FETCH_MODE" => "cors").first
      assert_equal 403, get("/", "HTTP_SEC_FETCH_SITE" => "cross-site", "HTTP_SEC_FETCH_MODE" => "no-cors").first
      assert_equal 200, get("/", "HTTP_SEC_FETCH_SITE" => "cross-site", "HTTP_SEC_FETCH_MODE" => "navigate").first, "following a link here"
      assert_equal 200, get("/", "HTTP_SEC_FETCH_SITE" => "none", "HTTP_SEC_FETCH_MODE" => "navigate").first, "typing the address"
      assert_equal 200, get("/", "HTTP_ORIGIN" => "http://localhost:3000", "HTTP_SEC_FETCH_SITE" => "same-origin").first
    end
  end

  def test_allowing_remote_visitors_keeps_the_name_and_other_site_checks
    ENV["DEADHEAT_DASHBOARD_ALLOW_REMOTE"] = "1"
    swap(Rails, :root, Pathname.new(@root)) do
      assert_equal 200, get("/", "REMOTE_ADDR" => "172.17.0.1").first, "a browser outside the container"
      assert_equal 403, get("/", "REMOTE_ADDR" => "172.17.0.1", "HTTP_HOST" => "evil.example.com").first
      assert_equal 403, get("/", "REMOTE_ADDR" => "172.17.0.1", "HTTP_ORIGIN" => "https://evil.example.com").first
    end
  ensure
    ENV.delete("DEADHEAT_DASHBOARD_ALLOW_REMOTE")
  end

  def test_the_dashboards_controller_is_not_loaded_when_the_app_boots
    script = 'require "rails"; require "action_controller"; require "deadheat"; ' \
             'exit(ActionController.autoload?(:Base) && Deadheat.autoload?(:ReportsController) ? 0 : 1)'
    assert system(Gem.ruby, "-I", File.expand_path("../../lib", __dir__), "-e", script), "requiring deadheat loaded Action Controller"
  end

  def test_the_page_may_load_nothing_and_cannot_be_framed
    swap(Rails, :root, Pathname.new(@root)) do
      _, text, headers = get("/")
      policy = headers["content-security-policy"]
      ["default-src 'none'", "base-uri 'none'", "form-action 'none'", "frame-ancestors 'none'"].each { |rule| assert_includes policy, rule }
      assert_includes text, %(content="#{Deadheat::Report::CONTENT_POLICY}")
      refute_match(/<script|<iframe|<form|<img|<link/i, text)
    end
  end

  def test_the_dashboard_refuses_ids_that_are_paths
    swap(Rails, :root, Pathname.new(@root)) do
      status, text, = get("/?id=../../../private")
      assert_equal 404, status
      refute_includes text, "SECRET"
      assert_equal 404, get("/?id[]=20260101-000000").first
      assert_equal 404, get("/runs/..%2F..%2F..%2Fprivate").first
    end
  end

  def test_the_dashboard_is_not_there_in_production
    swap(Rails, :env, ActiveSupport::EnvironmentInquirer.new("production")) do
      swap(Rails, :root, Pathname.new(@root)) do
        assert_equal 404, get("/").first
        assert_equal 404, get("/runs/20260101-000000").first
      end
    end
  end

  def test_everything_from_a_results_file_is_escaped
    attack = %(<script>alert(1)</script>)
    finding = { status: "race", kind: "made_twice", title: attack, lines: [attack], why: attack, fixes: [attack], try: attack,
                pauses: attack, count: attack, actors: [attack, "b"],
                timeline: [{ actor: attack, kind: attack, sql: attack, tables: ["t"], at_ms: attack, source: attack, pause: attack, paused_ms: 3 }] }
    File.write(File.join(@run, "two.json"), JSON.generate(name: attack, location: attack, database: attack, tries: attack,
      counts: { race: 1 }, findings: [finding], reproduce: attack,
      sweep: { method: attack, route: attack, name: attack, file: attack }))
    File.write(File.join(@run, "sweep.json"), JSON.generate(seconds: attack, coverage: { share: 0.5, checked: attack, write_endpoints: attack }))
    page = Deadheat::Report.html(Deadheat::Report.load(@root))
    refute_includes page, "<script>"
    assert_includes page, "&lt;script&gt;"
  end
end

class RegressionTestWriterTest < Minitest::Test
  def test_text_from_a_test_run_cannot_become_code
    hostile = %(/x"; File.write("/tmp/pwned", "1"); "\#{File.write('/tmp/pwned', '1')}\nFile.write("/tmp/pwned", "1"))
    target = { "method" => "POST", "route" => nil, "path" => hostile, "test" => %(Evil#test_"\#{File.write('/tmp/pwned', '1')}"\nFile.write('/tmp/pwned', '1')),
               "file" => %(test/x"\#{File.write('/tmp/pwned', '1')}.rb), "index" => 2, "line" => 5 }
    result = { target: target, status: "race", title: %(Made twice\nFile.write("/tmp/pwned", "1")) }

    Dir.mktmpdir do |root|
      %w[minitest rspec].each do |framework|
        runner = Deadheat::Sweep::Runner.new(root: root, framework: framework, out: StringIO.new)
        path = runner.send(:write_regression_tests, [result]).first
        assert path.start_with?(File.join(root, framework == "rspec" ? "spec/races/sweep/" : "test/races/sweep/")), path
        assert_operator File.basename(path).length, :<, 120
        parsed = Prism.parse(File.read(path))
        assert parsed.success?, "the generated #{framework} file is valid Ruby"
        assert_empty calls_named(parsed.value, :write), "nothing from the test run became a call"
      end
    end
  end

  def test_a_sweep_that_could_check_nothing_does_not_pass
    out = StringIO.new
    runner = Deadheat::Sweep::Runner.new(root: Dir.mktmpdir, framework: "minitest", out: out, write_tests: false)
    summary = Deadheat::Sweep::Runner::Summary.new(results: [{ status: "unchecked", target: {} }], targets: [{}], requests: [{}], routes: [],
      coverage: { share: nil }, dir: Dir.mktmpdir, seconds: 1.0, errors: [])
    assert_equal 2, runner.exit_code(summary)
    FileUtils.mkdir_p(runner.instance_variable_get(:@dir))
    runner.send(:finish, summary)
    assert_includes out.string, "Nothing could be checked"
    refute_includes out.string, "No races found"
  end

  def test_the_request_number_must_be_a_number
    runner = Deadheat::Sweep::Runner.new(root: Dir.pwd, framework: "minitest", out: StringIO.new)
    target = { "method" => "POST", "route" => "/x", "test" => "T#test_x", "file" => "test/x_test.rb", "index" => "2; exit" }
    assert_raises(ArgumentError) { runner.send(:minitest_regression, target, { title: "x" }, "post_x") }
  end

  private

  def calls_named(node, name, found = [])
    found << node if node.is_a?(Prism::CallNode) && node.name == name
    node.compact_child_nodes.each { |child| calls_named(child, name, found) }
    found
  end
end

class RedactTest < Minitest::Test
  def setup
    @before = ActiveRecord::Base.filter_attributes
    ActiveRecord::Base.filter_attributes = %i[passw email token]
  end

  def teardown
    ActiveRecord::Base.filter_attributes = @before
  end

  def attribute(name)
    ActiveModel::Attribute.with_cast_value(name, "x", ActiveModel::Type::Value.new)
  end

  def test_columns_the_app_hides_from_its_logs_are_hidden
    assert Deadheat::Redact.hidden?("password_digest")
    assert Deadheat::Redact.hidden?(:email)
    refute Deadheat::Redact.hidden?("stock")
    refute Deadheat::Redact.hidden?(nil)
  end

  def test_bound_values_are_hidden_by_column
    payload = { sql: %(UPDATE "users" SET "password_digest" = $1, "name" = $2 WHERE "users"."id" = $3),
                binds: [attribute("password_digest"), attribute("name"), attribute("id")], type_casted_binds: ["$2a$04$secret", "Ann", 5] }
    assert_equal %(UPDATE "users" SET "password_digest" = [FILTERED], "name" = 'Ann' WHERE "users"."id" = 5), Deadheat::SQL.readable(payload)
  end

  def test_values_written_into_the_statement_are_hidden
    apostrophe = Deadheat::Redact.backslash_escapes? ? %q(\') : "''" # how this database writes ' inside a value
    assert_equal "SELECT `users`.* FROM `users` WHERE `users`.`email` = [FILTERED] AND `users`.`id` = 5",
      Deadheat::SQL.readable({ sql: "SELECT `users`.* FROM `users` WHERE `users`.`email` = 'o#{apostrophe}brien@example.com' AND `users`.`id` = 5" })
    assert_equal "INSERT INTO `sessions` (`user_id`, `token`) VALUES ([FILTERED])",
      Deadheat::SQL.readable({ sql: "INSERT INTO `sessions` (`user_id`, `token`) VALUES (5, 'tok_123')" })
    assert_equal "INSERT INTO `orders` (`user_id`, `product_id`) VALUES (5, 37)",
      Deadheat::SQL.readable({ sql: "INSERT INTO `orders` (`user_id`, `product_id`) VALUES (5, 37)" })
  end

  def test_changed_rows_saved_in_the_results_file_hide_those_columns
    schema = Deadheat::Schema.new(Deadheat::Preflight.database!)
    before = Deadheat::Snapshot.take(schema)
    Member.create!(team: Team.create!(name: "Redact", budget: 1), email: "new@example.com", password: "password123")
    saved = Deadheat::Canon.build(schema, before, Deadheat::Snapshot.take(schema)).to_h.to_json
    assert_includes saved, %(["email","[FILTERED]"])
    refute_includes saved, "new@example.com"
    refute_match(/\$2[aby]\$/, saved, "no password hash in the file")
  ensure
    before&.restore
  end

  def test_a_hidden_column_named_anywhere_hides_every_quoted_value
    assert_equal "SELECT 1 FROM users WHERE lower(email) = lower([FILTERED])",
      Deadheat::SQL.readable({ sql: "SELECT 1 FROM users WHERE lower(email) = lower('Bob@Example.com')" })
    assert_equal "SELECT 1 FROM sessions WHERE token IN ([FILTERED]) AND kind = [FILTERED]",
      Deadheat::SQL.readable({ sql: "SELECT 1 FROM sessions WHERE token IN ('a', 'b') AND kind = 'web'" })
    assert_equal "SELECT 1 FROM products WHERE name = 'email'", Deadheat::SQL.readable({ sql: "SELECT 1 FROM products WHERE name = 'email'" }),
      "a value that happens to be a column's name hides nothing"
  end

  def test_other_ways_of_quoting_a_value_are_hidden_too
    {
      %(UPDATE users SET token = "in double quotes" WHERE id = 5) => "UPDATE users SET token = [FILTERED] WHERE id = 5",
      %(UPDATE users SET token = $$dollar quoted$$ WHERE id = 5) => "UPDATE users SET token = [FILTERED] WHERE id = 5",
      %(UPDATE users SET token = $t$tagged 'quote'$t$ WHERE id = 5) => "UPDATE users SET token = [FILTERED] WHERE id = 5",
      %(UPDATE users SET token = E'escaped' WHERE id = 5) => "UPDATE users SET token = [FILTERED] WHERE id = 5",
      %(UPDATE users SET token = X'DEADBEEF' WHERE id = 6) => "UPDATE users SET token = [FILTERED] WHERE id = 6",
      %(SELECT 1 FROM users WHERE token IN('a', 'b')) => "SELECT 1 FROM users WHERE token IN([FILTERED])",
      %(SELECT 1 FROM users WHERE lower(email) = lower($$Bob@Example.com$$)) => "SELECT 1 FROM users WHERE lower(email) = lower([FILTERED])"
    }.each { |sql, shown| assert_equal shown, Deadheat::SQL.readable({ sql: sql }) }
  end

  def test_a_backslash_before_a_quote_cannot_move_where_a_value_ends
    skip "MySQL reads a backslash as an escape" if Deadheat::Redact.backslash_escapes?
    shown = Deadheat::SQL.readable({ sql: %q(UPDATE users SET name = 'foo\', token = 'SECRET1' WHERE id = 1) })
    refute_includes shown, "SECRET1"
    assert_equal "UPDATE users SET name = [FILTERED], token = [FILTERED] WHERE id = 1", shown
  end

  def test_numbers_lists_and_ranges_of_a_hidden_column_are_hidden
    {
      "SELECT 1 FROM users WHERE token IN (123456, 99) AND id IN (1, 2)" => "SELECT 1 FROM users WHERE token IN ([FILTERED]) AND id IN (1, 2)",
      "SELECT 1 FROM users WHERE token >= 123456 AND stock >= 3" => "SELECT 1 FROM users WHERE token >= [FILTERED] AND stock >= 3",
      "SELECT 1 FROM users WHERE token BETWEEN 100 AND 200 AND id BETWEEN 1 AND 9" => "SELECT 1 FROM users WHERE token BETWEEN [FILTERED] AND id BETWEEN 1 AND 9",
      "UPDATE users SET token = 0xDEADBEEF WHERE id = 5" => "UPDATE users SET token = [FILTERED] WHERE id = 5",
      "SELECT 1 FROM users WHERE data->>'token' = 'SECRET3'" => "SELECT 1 FROM users WHERE data->>[FILTERED] = [FILTERED]"
    }.each { |sql, shown| assert_equal shown, Deadheat::SQL.readable({ sql: sql }) }
  end

  def test_a_redirect_hides_the_parameters_the_app_hides
    assert_equal "/done?token=[FILTERED]&page=2", Deadheat::Redact.url("/done?token=SECRET123&page=2")
    assert_equal "/done?user[password]=[FILTERED]#top", Deadheat::Redact.url("/done?user[password]=hunter2#top")
    assert_equal "/orders/7?page=2", Deadheat::Redact.url("/orders/7?page=2")
    assert_equal "/orders/7", Deadheat::Redact.url("/orders/7")
  end

  def test_a_very_long_value_does_not_slow_the_query_down
    blob = "ab" * 100_000
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    Deadheat::Redact.sql("INSERT INTO files (name, token, body) VALUES ('a.png', 't', x'#{blob}')")
    Deadheat::Redact.sql("UPDATE files SET body = x'#{blob}', token = 'abc' WHERE id = 1")
    Deadheat::Redact.sql("INSERT INTO files (name, body) VALUES ('a.png', x'#{blob}')")
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :<, 1.0
  end

  def test_what_is_not_a_value_is_left_alone
    [
      %(SELECT 1 FROM "users" INNER JOIN "invites" ON "users"."email" = "invites"."email"),
      %(UPDATE "users" SET "name" = $1 WHERE "users"."id" = $2),
      %(SELECT 1 FROM products WHERE name = "Shirt" AND stock = 3)
    ].each { |sql| assert_equal sql, Deadheat::SQL.readable({ sql: sql }) }
  end

  def test_extra_emails_hide_the_address_when_the_app_hides_emails
    lines, = Deadheat::Effects.new(mails: [["a@example.com", "Your order"]] * 2).extra_over(Deadheat::Effects.new(mails: [["a@example.com", "Your order"]]))
    assert_equal ["1 extra email to [FILTERED]: “Your order”"], lines
  end

  def test_nothing_is_hidden_when_the_app_hides_nothing
    ActiveRecord::Base.filter_attributes = []
    refute Deadheat::Redact.hidden?("password_digest")
    assert_equal "SELECT 1 FROM users WHERE email = 'a@example.com'", Deadheat::SQL.readable({ sql: "SELECT 1 FROM users WHERE email = 'a@example.com'" })
  end
end

class RestoreSafetyTest < DeadheatIntegrationTest
  def swap(object, name, value)
    original = object.method(name)
    object.define_singleton_method(name) { value }
    yield
  ensure
    object.define_singleton_method(name, original)
  end

  teardown do
    Comment.delete_all
    Post.delete_all
    User.delete_all
  end

  test "rows the database deletes by itself are put back, and every try starts with them" do
    post = Post.create!(title: "Hello")
    3.times { |i| Comment.create!(post: post, body: "comment #{i}") }
    seen = Concurrent::Array.new
    result = race("two deletes of one post") do |r|
      2.times do
        r.run do
          seen << Comment.where(post_id: post.id).count
          Post.where(id: post.id).delete_all
        end
      end
    end
    assert_no_findings(result)
    assert_includes result.expected[:changes].keys, "comments", "the cascade is part of what's compared"
    assert seen.include?(3), "comments were there at the start of a run"
    assert Post.exists?(post.id), "the post is back"
    assert_equal 3, Comment.where(post_id: post.id).count, "and so are its comments"
  end

  test "a table nobody wrote to is not reported as changed" do
    User.create!(name: "Bystander")
    post = Post.create!(title: "Likes")
    result = race("likes") do |r|
      2.times { r.run { Post.update_counters(post.id, likes_count: 1) } }
    end
    assert_no_findings(result)
    assert_equal ["posts"], result.expected[:changes].keys
  end

  test "a snapshot is never restored outside the test environment" do
    Post.create!(title: "Stays")
    snapshot = Deadheat::Snapshot.take(Deadheat::Schema.new(Deadheat::Preflight.database!), ["posts"])
    swap(Rails, :env, ActiveSupport::EnvironmentInquirer.new("development")) do
      assert_raises(Deadheat::Refused) { snapshot.restore }
    end
    assert_equal 1, Post.count
  end

  test "real email delivery is refused" do
    before = ActionMailer::Base.delivery_method
    ActionMailer::Base.delivery_method = :smtp
    error = assert_raises(Deadheat::Refused) { Deadheat::Preflight.check! }
    assert_match(/delivery_method = :test/, error.message)
  ensure
    ActionMailer::Base.delivery_method = before
  end
end

class WriteTablesTest < Minitest::Test
  SQL = Deadheat::SQL

  def test_more_kinds_of_write_are_read
    assert_equal ["orders"], SQL.tables(%(INSERT OR IGNORE INTO "orders" ("a") VALUES (1)))
    assert_equal ["logs"], SQL.tables(%(WITH x AS (SELECT 1) INSERT INTO "logs" ("a") SELECT 1))
    assert_equal :write, SQL.kind("TRUNCATE TABLE carts")
    assert_equal ["carts"], SQL.tables("TRUNCATE TABLE carts")
    assert_equal ["stock"], SQL.tables(%(MERGE INTO "stock" USING incoming ON true WHEN MATCHED THEN UPDATE SET n = 1))
  end

  def test_a_write_that_cant_be_read_means_every_table
    schema = Struct.new(:tables) { def with_cascades(names) = names & tables }.new(%w[a b c])
    Deadheat::Writes.clear
    Deadheat::Writes.note({ sql: %(UPDATE "a" SET x = 1) })
    assert_equal ["a"], Deadheat::Writes.tables_in(schema)
    Deadheat::Writes.note({ sql: "MERGE whatever" })
    assert_equal %w[a b c], Deadheat::Writes.tables_in(schema)
  ensure
    Deadheat::Writes.clear
  end
end
