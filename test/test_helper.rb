ENV["RAILS_ENV"] = "test"
ENV["DEADHEAT_TRIES"] ||= "12"

$LOAD_PATH.unshift File.expand_path("../lib", __dir__)
require_relative "dummy/config/environment"
require "rails/test_help"
require "deadheat/minitest"

Deadheat.config.results_dir = File.expand_path("../tmp/deadheat", __dir__)

require_relative "support/database"

module RaceHelpers
  # Runs a race and returns its result, without failing the test, so the test can check what it found.
  def race(name = "race", tries: nil, &block)
    Deadheat::Race.new(self, name, tries: tries, &block).run
  end

  # Rails 8 starts SQLite write transactions with BEGIN IMMEDIATE, which takes the write lock before
  # the first read. Check-then-insert inside one transaction (a uniqueness validation during save) is
  # therefore serialized there and really can't race.
  def serializes_transactions?
    ActiveRecord::Base.connection.adapter_name.match?(/sqlite/i) && Rails::VERSION::MAJOR >= 8
  end

  def kinds(result)
    result.findings.map(&:kind)
  end

  def assert_no_findings(result)
    assert result.passed?, -> { "expected no race, got:\n#{result.failure_message}" }
    assert_equal 0, result.counts[:race].to_i, -> { result.failure_message }
  end
end

class DeadheatIntegrationTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false
  include RaceHelpers
end
