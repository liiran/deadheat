require "minitest/autorun"
require "json"
require "open3"

# Runs `bin/deadheat sweep` on the Corner Store demo app, from the outside, the way a person would,
# and checks what it found. Slow (a minute or two per database), so it's its own task:
#   docker compose run --rm dev bundle exec rake test:sweep
class DemoSweepTest < Minitest::Test
  DEMO = File.expand_path("../../demo", __dir__)
  DB = ENV.fetch("DB", "sqlite")

  # Runs the sweep and returns its output, exit status and the summary it wrote. The summary must be
  # from this run: one that was already there doesn't count.
  def sweep(flags = "")
    before = Dir[File.join(DEMO, "tmp/deadheat/runs/*/sweep.json")]
    output, status = run_sweep(flags)
    fresh = Dir[File.join(DEMO, "tmp/deadheat/runs/*/sweep.json")] - before
    assert_equal 1, fresh.size, "the sweep wrote no summary:\n#{output}"
    [output, status, JSON.parse(File.read(fresh.first))]
  end

  def run_sweep(flags)
    # The demo has its own Gemfile; don't let this repo's Bundler settings leak into it.
    env = { "DB" => DB, "BUNDLE_GEMFILE" => File.join(DEMO, "Gemfile"), "RUBYOPT" => nil, "BUNDLE_BIN_PATH" => nil }
    Open3.capture2e(env, "sh", "-c", "bin/rails db:create db:schema:load >/dev/null 2>&1; bin/deadheat sweep --no-tests --tries 10 #{flags}", chdir: DEMO)
  end

  def test_finds_every_planted_race_and_no_fixed_one
    output, status, summary = sweep
    assert_equal 1, status.exitstatus, output
    results = summary["results"]
    shop = results.reject { |r| r.dig("target", "route").to_s.start_with?("/fixed") || r.dig("target", "endpoint").to_s.match?(/Sessions|Passwords/) }
    fixed = results.select { |r| r.dig("target", "route").to_s.start_with?("/fixed") }
    found = shop.select { |r| r["status"] == "race" }.map { |r| r.dig("target", "route") }.sort

    # Rails 8 runs SQLite writes with BEGIN IMMEDIATE, so a uniqueness validation and its insert, all
    # inside one transaction, really can't race there. That takes out the newsletter and the follow.
    expected = DB == "sqlite" ? 8 : 10
    assert_equal expected, found.size, "found #{found.inspect}\n#{output}"
    assert_equal 10, fixed.size, output
    assert_empty fixed.reject { |r| r["status"] == "ok" }, "false alarms:\n#{output}"
    assert_operator shop.count { |r| r["irreversible"] }, :>=, 2, output
    assert summary.dig("coverage", "share").to_f > 0.7, summary["coverage"].inspect
  end
  def test_rspec_request_specs_too
    output, status, summary = sweep("--rspec")
    assert_equal 1, status.exitstatus, output
    assert_equal "rspec", summary["framework"]
    races = summary["results"].select { |r| r["status"] == "race" }.map { |r| r.dig("target", "route") }
    fixed = summary["results"].select { |r| r.dig("target", "route").to_s.start_with?("/fixed") }
    # The four specs are buy, coupon, wallet and follow. The follow can't race on SQLite (see above).
    assert_equal DB == "sqlite" ? 3 : 4, races.size, output
    assert(races.none? { |route| route.start_with?("/fixed") }, output)
    assert_equal 4, fixed.size, output
  end
end
