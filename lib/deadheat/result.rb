module Deadheat
  # What a whole race found over all its tries.
  class Result
    attr_reader :name, :location, :database, :tries, :counts, :findings, :seed, :expected,
                :warnings, :seconds, :actors, :reproduce

    def initialize(name:, location:, database:, tries:, counts:, findings:, seed:, expected:, warnings:, seconds:, actors:, reproduce: nil)
      @name = name
      @location = location
      @database = database
      @tries = tries
      @counts = counts
      @findings = findings
      @seed = seed
      @expected = expected
      @warnings = warnings
      @seconds = seconds
      @actors = actors
      @reproduce = reproduce
    end

    def races
      findings.select { |f| f.status == :race }
    end

    def crashes
      findings.select { |f| f.status == :crash }
    end

    # A race test passes when no try produced wrong data or a crash. Being "protected" is fine.
    def passed?
      races.empty? && crashes.empty? && !findings.any? { |f| f.status == :hung }
    end

    def broken_tries
      counts[:race].to_i + counts[:crash].to_i
    end

    def irreversible?
      findings.any?(&:irreversible)
    end

    def failure_message
      Format.result(self)
    end

    def to_h
      {
        name: name, location: location, database: database, tries: tries, counts: counts, seed: seed,
        passed: passed?, irreversible: irreversible?, seconds: seconds, actors: actors,
        expected: expected, warnings: warnings, reproduce: reproduce,
        findings: findings.map(&:to_h)
      }
    end
  end
end
