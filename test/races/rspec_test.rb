require_relative "../test_helper"
require "open3"

# Runs the RSpec suite in test/rspec in its own process and database, and checks every example.
class RSpecSupportTest < ActiveSupport::TestCase
  test "race specs fail on the bugs, pass on the fixes, and leave other specs alone" do
    out = File.expand_path("../../tmp/rspec.json", __dir__)
    env = { "DEADHEAT_DB_NAME" => "deadheat_rspec_test" }
    _stdout, stderr, _status = Open3.capture3(env, Gem.ruby, "-S", "rspec", "test/rspec/race_spec.rb", "--order", "defined", "--format", "json", "--out", out,
                                              chdir: File.expand_path("../..", __dir__))
    examples = JSON.parse(File.read(out))["examples"].to_h { |e| [e["description"], e] }
    assert_equal 6, examples.size, stderr
    assert_equal "failed", examples["BUGGY likes counter"]["status"]
    assert_match(/Lost update: posts #\d+ likes_count went 0 → 1/, examples["BUGGY likes counter"].dig("exception", "message"))
    assert_equal "passed", examples["FIXED likes counter"]["status"], examples["FIXED likes counter"].dig("exception", "message")
    assert_equal "failed", examples["BUGGY shared budget"]["status"]
    assert_match(/Went below zero: teams #\d+ budget ended at -60/, examples["BUGGY shared budget"].dig("exception", "message"))
    assert_match(%r{Reproduce: DEADHEAT_SEED=\d+ bundle exec rspec test/rspec/race_spec.rb:\d+}, examples["BUGGY shared budget"].dig("exception", "message"))
    assert_equal "passed", examples["FIXED shared budget"]["status"], examples["FIXED shared budget"].dig("exception", "message")
    assert_equal "passed", examples["leaves no rows behind"]["status"]
    assert_equal "passed", examples["starts empty, because every race cleaned up"]["status"], examples["starts empty, because every race cleaned up"].dig("exception", "message")
  end
end
