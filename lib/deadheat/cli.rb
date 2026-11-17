require "optparse"

module Deadheat
  # bin/deadheat: sweep, scan and report. Run it from the app's root folder.
  class CLI
    USAGE = <<~TEXT.freeze
      Dead Heat finds the bugs that only happen when two requests arrive at once.

      Usage:
        bin/deadheat sweep [paths] [options]   Send each write request your tests make twice at once
        bin/deadheat scan [paths]              Read the code and list places that look racy (no database)
        bin/deadheat report [--open]           Write the latest results as one HTML page

      Sweep options:
        --all          Check every write request, not just one per endpoint
        --tries N      Tries per request (default 20)
        --rspec        Use RSpec (detected by default)
        --minitest     Use Minitest (detected by default)
        --no-tests     Don't write regression tests for what's found

      A test location works as a path too: bin/deadheat sweep test/integration/checkout_test.rb:12
    TEXT

    def self.start(argv = ARGV, out: $stdout)
      new(argv, out).run
    end

    def initialize(argv, out)
      @argv = argv.dup
      @out = out
    end

    def run
      command = @argv.shift
      case command
      when "sweep" then sweep
      when "scan" then scan
      when "report" then report
      when nil, "-h", "--help", "help" then @out.puts(USAGE) || 0
      when "-v", "--version" then @out.puts("deadheat #{VERSION}") || 0
      else
        @out.puts("Unknown command “#{command}”.\n\n#{USAGE}")
        64
      end
    end

    private

    def sweep
      options = { all: false, tries: nil, framework: nil, write_tests: true }
      parser = OptionParser.new do |o|
        o.on("--all") { options[:all] = true }
        o.on("--tries N", Integer) { |n| options[:tries] = n }
        o.on("--rspec") { options[:framework] = "rspec" }
        o.on("--minitest") { options[:framework] = "minitest" }
        o.on("--no-tests") { options[:write_tests] = false }
      end
      paths = parser.parse(@argv)
      require "deadheat/sweep/runner"
      runner = Sweep::Runner.new(paths: paths, out: @out, **options)
      runner.exit_code(runner.run)
    end

    def scan
      require "deadheat/scan"
      Scan.start(@argv, out: @out)
    end

    def report
      require "deadheat/report"
      Report.start(@argv, out: @out)
    end
  end
end
