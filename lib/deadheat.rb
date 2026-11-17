require "active_support"
require "active_support/core_ext"
require "active_record"
require "concurrent"
require "json"
require "digest"

require_relative "deadheat/version"

# Dead Heat finds race conditions: bugs that only happen when two requests (or jobs) touch the same
# data at the same moment. It runs the actions together, with small targeted pauses that widen the
# gaps where races live, and compares the result with running them one after another.
module Deadheat
  class Error < StandardError; end

  # Raised when Dead Heat won't run because the setup would make its results wrong or unsafe.
  # The message always says what to change.
  class Refused < Error; end

  # Raised when a racing thread doesn't finish within the time limit.
  class Hung < Error; end

  # Thrown into a test to end it early once Dead Heat has what it needs. It isn't a StandardError,
  # so the test's own `rescue => e` blocks don't swallow it.
  class Stop < Exception; end # rubocop:disable Lint/InheritException

  autoload :Config, "deadheat/config"
  autoload :SQL, "deadheat/sql"
  autoload :Source, "deadheat/source"
  autoload :Actor, "deadheat/actor"
  autoload :Probe, "deadheat/probe"
  autoload :Writes, "deadheat/writes"
  autoload :PausePlan, "deadheat/pause_plan"
  autoload :Racer, "deadheat/racer"
  autoload :Schema, "deadheat/schema"
  autoload :Snapshot, "deadheat/snapshot"
  autoload :Canon, "deadheat/canon"
  autoload :Effects, "deadheat/effects"
  autoload :Outcome, "deadheat/outcome"
  autoload :Verdict, "deadheat/verdict"
  autoload :Finding, "deadheat/finding"
  autoload :Explain, "deadheat/explain"
  autoload :Fixes, "deadheat/fixes"
  autoload :Preflight, "deadheat/preflight"
  autoload :Sessions, "deadheat/sessions"
  autoload :Race, "deadheat/race"
  autoload :Result, "deadheat/result"
  autoload :Results, "deadheat/results"
  autoload :Ping, "deadheat/ping"
  autoload :Format, "deadheat/format"
  autoload :Sweep, "deadheat/sweep"

  class << self
    def config
      @config ||= Config.new
    end

    def configure
      yield config
    end

    # Errors inside Dead Heat's own listeners must never break the app's query, so they're kept here
    # and shown once at the end instead.
    def internal_errors
      @internal_errors ||= Concurrent::Array.new
    end

    def internal_error(error)
      internal_errors << error if internal_errors.size < 20
    end

    def now
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end

if defined?(Rails::Railtie)
  require_relative "deadheat/railtie"
  require_relative "deadheat/engine"
end
