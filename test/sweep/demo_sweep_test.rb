require "minitest/autorun"
require "json"
require "open3"

# Runs `bin/deadheat sweep` on the Corner Store demo app, from the outside, the way a person would,
# and checks what it found. Slow (a minute or two per database), so it's its own task:
#   docker compose run --rm dev bundle exec rake test:sweep
class DemoSweepTest < Minitest::Test
  DEMO = File.expand_path("../../demo", __dir__)
  DB = ENV.fetch("DB", "sqlite")

  def sweep
    # The demo has its own Gemfile; don't let this repo's Bundler settings leak into it.
    env = { "DB" => DB, "BUNDLE_GEMFILE" => File.join(DEMO, "Gemfile"), "RUBYOPT" => nil, "BUNDLE_BIN_PATH" => nil }
    Open3.capture2e(env, "sh", "-c", "bin/rails db:create db:schema:load >/dev/null 2>&1; bin/deadheat sweep --no-tests --tries 10", chdir: DEMO)
  end

  def test_finds_every_planted_race_and_no_fixed_one
    output, status = sweep
    assert_equal 1, status.exitstatus, output
    latest = Dir[File.join(DEMO, "tmp/deadheat/runs/*/sweep.json")].max_by { |path| File.mtime(path) }
    summary = JSON.parse(File.read(latest))
    results = summary["results"]
    shop = results.reject { |r| r.dig("target", "route").to_s.start_with?("/fixed") || r.dig("target", "endpoint").to_s.match?(/Sessions|Passwords/) }
    fixed = results.select { |r| r.dig("target", "route").to_s.start_with?("/fixed") }
    found = shop.select { |r| r["status"] == "race" }.map { |r| r.dig("target", "route") }.sort

    # Rails 8 runs SQLite writes with BEGIN IMMEDIATE, so the newsletter's validate-then-insert,
    # all inside one transaction, really can't race there.
    expected = DB == "sqlite" ? 9 : 10
    assert_equal expected, found.size, "found #{found.inspect}\n#{output}"
    assert_equal 10, fixed.size, output
    assert_empty fixed.reject { |r| r["status"] == "ok" }, "false alarms:\n#{output}"
    assert_operator shop.count { |r| r["irreversible"] }, :>=, 2, output
    assert summary.dig("coverage", "share").to_f > 0.7, summary["coverage"].inspect
  end
end
