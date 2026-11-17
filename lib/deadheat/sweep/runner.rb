require "deadheat"
require "fileutils"
require "open3"
require "securerandom"

module Deadheat
  module Sweep
    # Runs a sweep from outside the test process: record the requests, choose what to check, run each
    # chosen test again in race mode, then sum up. It only starts test commands and reads their files,
    # so it doesn't load the app itself.
    class Runner
      WRITE_VERBS = /\A(?:POST|PUT|PATCH|DELETE)\z/

      Summary = Struct.new(:results, :targets, :requests, :routes, :coverage, :dir, :seconds, :errors, keyword_init: true) do
        def races
          results.select { |r| %w[race crash].include?(r[:status]) }
        end
      end

      def initialize(paths: [], all: false, tries: nil, framework: nil, out: $stdout, root: Dir.pwd, write_tests: true, run_id: nil)
        @paths = paths
        @all = all
        @tries = tries
        @root = root
        @framework = framework || detect_framework
        @out = out
        @write_tests = write_tests
        @run_id = run_id || "#{Time.now.utc.strftime('%Y%m%d-%H%M%S')}-#{SecureRandom.hex(2)}"
        @dir = File.join(root, "tmp/deadheat/runs", @run_id)
      end

      def run
        started = Deadheat.now
        FileUtils.mkdir_p(@dir)
        say "Dead Heat sweep (#{@framework == 'rspec' ? 'RSpec' : 'Minitest'})"
        say "Recording the requests your tests make…"
        requests, routes = record
        writes = requests.select { |r| r["writes"].to_i.positive? && r["endpoint"] }
        if requests.empty?
          say "No request or integration tests made any requests, so there's nothing to sweep."
          say "(The test output is in #{relative(File.join(@dir, 'record.log'))}.)"
          return Summary.new(results: [], targets: [], requests: [], routes: routes, coverage: coverage(routes, []), dir: @dir, seconds: elapsed(started), errors: [])
        end

        targets = choose(writes)
        tests = requests.map { |r| r["test"] }.uniq.size
        say "Found #{count(writes.size, 'write request')} in #{count(tests, 'test')}. Checking #{count(targets.size, 'endpoint')}, #{tries_label}…"
        say ""
        errors = []
        rounds(targets).each { |round| race_round(round, errors) }
        results = collect(targets)
        summary = Summary.new(results: results, targets: targets, requests: requests, routes: routes,
                              coverage: coverage(routes, targets), dir: @dir, seconds: elapsed(started), errors: errors)
        finish(summary)
        summary
      end

      def exit_code(summary)
        return 2 if summary.requests.empty? && summary.targets.empty?

        summary.races.any? ? 1 : 0
      end

      # Runs one target again on its own (used by generated regression tests).
      def recheck(test:, file:, index:)
        FileUtils.mkdir_p(@dir)
        target = { "test" => test, "file" => file, "index" => index, "method" => "?", "route" => "?" }
        race_round([target], [])
        collect([target]).first
      end

      private

      def detect_framework
        rspec = File.exist?(File.join(@root, ".rspec")) || Dir.exist?(File.join(@root, "spec"))
        rspec && !Dir.exist?(File.join(@root, "test/integration")) && !Dir.exist?(File.join(@root, "test/controllers")) ? "rspec" : "minitest"
      end

      # 1. Run the tests once with the recorder on.
      def record
        file = File.join(@dir, "record.jsonl")
        env = base_env.merge("DEADHEAT_SWEEP" => "record", "DEADHEAT_SWEEP_OUT" => file)
        run_command(env, record_command, File.join(@dir, "record.log"))
        lines = File.exist?(file) ? File.readlines(file).map { |line| JSON.parse(line) } : []
        routes = lines.find { |line| line["routes"] }&.fetch("routes") || []
        [lines.reject { |line| line["routes"] }, routes]
      end

      def record_command
        if @framework == "rspec"
          [*bundle, "rspec", *(@paths.empty? ? default_spec_paths : @paths)]
        else
          [*rails, "test", *@paths]
        end
      end

      def default_spec_paths
        found = %w[spec/requests spec/integration spec/api].select { |dir| Dir.exist?(File.join(@root, dir)) }
        found.empty? ? ["spec"] : found
      end

      # One request per endpoint (method + route), from the test that reaches it soonest, unless --all.
      def choose(writes)
        return writes.uniq { |r| [r["test"], r["index"]] } if @all

        writes.group_by { |r| endpoint_label(r) }.map { |_, list| list.min_by { |r| [r["index"], r["test"]] } }
      end

      # A test can be the target for more than one request. Each run of a test races one request, so
      # those go in separate rounds.
      def rounds(targets)
        by_test = targets.group_by { |t| t["test"] }.transform_values { |list| list.sort_by { |t| t["index"] } }
        depth = by_test.values.map(&:size).max.to_i
        (0...depth).map { |i| by_test.values.filter_map { |list| list[i] } }
      end

      # 2. Run each chosen test again in race mode, one process per test file.
      def race_round(round, errors)
        round.group_by { |t| t["file"] }.each do |file, list|
          targets_file = File.join(@dir, "targets-#{SecureRandom.hex(4)}.json")
          File.write(targets_file, JSON.generate(list))
          env = base_env.merge("DEADHEAT_SWEEP" => "race", "DEADHEAT_SWEEP_TARGETS" => targets_file, "PARALLEL_WORKERS" => "1")
          log = File.join(@dir, "race-#{File.basename(file, '.rb')}-#{SecureRandom.hex(2)}.log")
          run_command(env, race_command(file, list), log)
          list.each do |target|
            result = find_result(target)
            if result
              say line_for(target, result)
            else
              errors << { target: target, log: log }
              say format("  ? %-34s couldn't be checked: the test stopped before this request (see %s)", endpoint_label(target), relative(log))
            end
          end
        end
      end

      def race_command(file, list)
        if @framework == "rspec"
          [*bundle, "rspec", *list.map { |t| t["test"] }]
        else
          pattern = "/^(?:#{list.map { |t| Regexp.escape(t['test']) }.join('|')})$/"
          [*rails, "test", file, "-n", pattern]
        end
      end

      def base_env
        env = { "RAILS_ENV" => "test", "DEADHEAT_RUN_ID" => @run_id, "DEADHEAT_RESULTS_DIR" => File.join(@root, "tmp/deadheat") }
        env["DEADHEAT_TRIES"] = @tries.to_s if @tries
        if @framework == "rspec"
          env["SPEC_OPTS"] = [ENV["SPEC_OPTS"], "--require deadheat/sweep/rspec"].compact.join(" ")
        end
        env
      end

      def run_command(env, command, log)
        File.open(log, "w") do |io|
          Open3.popen2e(env, *command, chdir: @root) do |_stdin, output, wait|
            output.each_line { |line| io.write(line) }
            wait.value
          end
        end
      rescue Errno::ENOENT => e
        File.write(log, "Couldn't start #{command.first}: #{e.message}\n")
      end

      def rails
        File.exist?(File.join(@root, "bin/rails")) ? [Gem.ruby, "bin/rails"] : [*bundle, "rails"]
      end

      def bundle
        File.exist?(File.join(@root, "Gemfile")) ? ["bundle", "exec"] : []
      end

      def results
        @results ||= Dir[File.join(@dir, "*.json")].filter_map do |path|
          next if File.basename(path).start_with?("targets-", "sweep")

          data = JSON.parse(File.read(path))
          data if data["sweep"]
        end
      end

      def find_result(target)
        @results = nil
        results.find { |r| r.dig("sweep", "test") == target["test"] && r.dig("sweep", "index") == target["index"] }
      end

      def collect(targets)
        @results = nil
        targets.map do |target|
          data = find_result(target)
          next { target: target, status: "unchecked" } unless data

          finding = data["findings"].first
          status = finding ? finding["status"] : "ok"
          status = "ok" if finding && !%w[race crash differs protected hung].include?(status)
          {
            target: target, status: status, title: finding&.dig("title"), tries: data["tries"],
            broken: data["counts"].values_at("race", "crash").compact.sum, passed: data["passed"],
            irreversible: data["irreversible"], message: data["message"], database: data["database"],
            findings: data["findings"]
          }
        end
      end

      def coverage(routes, targets)
        writes = routes.select { |r| r["verb"].to_s.split("|").any? { |v| v.match?(WRITE_VERBS) } && r["endpoint"] }.uniq { |r| r["endpoint"] }
        checked = targets.map { |t| t["endpoint"] }.compact.uniq
        covered = writes.count { |r| checked.include?(r["endpoint"]) }
        { write_endpoints: writes.size, checked: covered, share: writes.empty? ? nil : (covered.to_f / writes.size).round(3) }
      end

      # 3. Sum up, save, and write regression tests for what was found.
      def finish(summary)
        say ""
        clean = summary.results.count { |r| r[:status] == "ok" || r[:status] == "protected" }
        races = summary.races
        notes = summary.results.count { |r| r[:status] == "differs" }
        say "  ✓ #{count(clean, 'endpoint')} with no race found" if clean.positive?
        say "  ~ #{count(notes, 'endpoint')} with different replies but right data" if notes.positive?
        cov = summary.coverage
        if cov[:share]
          say format("Checked %d of the app's %d write endpoints (%.0f%%) using its existing tests, with no setup.", cov[:checked], cov[:write_endpoints], cov[:share] * 100)
        end
        irreversible = races.count { |r| r[:irreversible] }
        verdict = races.empty? ? "No races found" : "#{count(races.size, 'race')} found#{" (#{irreversible} with side effects that can't be undone)" if irreversible.positive?}"
        say "#{verdict} in #{format_duration(summary.seconds)}."
        written = @write_tests ? write_regression_tests(races) : []
        say "Regression tests written: #{written.map { |path| relative(path) }.join(', ')}" if written.any?
        File.write(File.join(@dir, "sweep.json"), JSON.pretty_generate(
          run_id: @run_id, framework: @framework, seconds: summary.seconds, coverage: cov,
          requests: summary.requests.size, write_requests: summary.requests.count { |r| r["writes"].to_i.positive? },
          results: summary.results.map { |r| r.merge(target: r[:target]) }
        ))
        say "Details: bin/deadheat report" if races.any?
      end

      def write_regression_tests(races)
        races.filter_map do |result|
          target = result[:target]
          slug = endpoint_label(target).downcase.gsub(/[^a-z0-9]+/, "_").gsub(/\A_|_\z/, "")
          if @framework == "rspec"
            path = File.join(@root, "spec/races/sweep/#{slug}_race_spec.rb")
            body = rspec_regression(target, result)
          else
            path = File.join(@root, "test/races/sweep/#{slug}_race_test.rb")
            body = minitest_regression(target, result, slug)
          end
          next if File.exist?(path)

          FileUtils.mkdir_p(File.dirname(path))
          File.write(path, body)
          path
        end
      end

      def minitest_regression(target, result, slug)
        <<~RUBY
          require "test_helper"
          require "deadheat/minitest"

          # Written by `bin/deadheat sweep` on #{Time.now.strftime('%Y-%m-%d')}:
          #   #{endpoint_label(target)}: #{result[:title]}
          # It sends request #{target['index']} of #{target['test']} twice at the same moment, as the sweep did,
          # and fails while the race is there. Keep it, so the race can't quietly come back.
          class #{slug.camelize}RaceTest < ActiveSupport::TestCase
            self.use_transactional_tests = false if respond_to?(:use_transactional_tests=)

            test "#{endpoint_label(target)} survives being sent twice at once" do
              result = Deadheat::Sweep.recheck(test: #{target['test'].inspect}, file: #{target['file'].inspect}, index: #{target['index']})
              assert result[:passed], result[:message]
            end
          end
        RUBY
      end

      def rspec_regression(target, result)
        <<~RUBY
          require "rails_helper"
          require "deadheat"

          # Written by `bin/deadheat sweep` on #{Time.now.strftime('%Y-%m-%d')}:
          #   #{endpoint_label(target)}: #{result[:title]}
          # It sends request #{target['index']} of #{target['file']}:#{target['line']} twice at the same moment, as the
          # sweep did, and fails while the race is there. Keep it, so the race can't quietly come back.
          RSpec.describe "#{endpoint_label(target)} survives being sent twice at once" do
            it "has no race" do
              result = Deadheat::Sweep.recheck(test: #{target['test'].inspect}, file: #{target['file'].inspect}, index: #{target['index']}, framework: "rspec")
              expect(result[:passed]).to be(true), result[:message]
            end
          end
        RUBY
      end

      def line_for(target, result)
        finding = result["findings"].first
        broken = result["counts"].values_at("race", "crash").compact.sum
        label = endpoint_label(target)
        if finding.nil? || finding["status"] == "protected"
          format("  ✓ %-34s no race found in %d tries%s", label, result["tries"], finding ? " (protected)" : "")
        else
          mark = { "race" => "✗", "crash" => "!", "differs" => "~", "hung" => "!" }.fetch(finding["status"], "?")
          extra = finding["irreversible"] ? "  [irreversible]" : ""
          shown = %w[race crash hung].include?(finding["status"]) ? "#{broken}/#{result['tries']} tries" : "#{finding['count']}/#{result['tries']} tries"
          format("  %s %-34s %s  %s%s", mark, label, finding["title"], shown, extra)
        end
      end

      def endpoint_label(request)
        "#{request['method']} #{request['route'] || request['path']}"
      end

      def tries_label
        "#{@tries || ENV.fetch('DEADHEAT_TRIES', 20)} tries each"
      end

      def count(number, noun)
        "#{number} #{number == 1 ? noun : noun.pluralize}"
      end

      def say(text)
        @out.puts(text)
      end

      def relative(path)
        path.delete_prefix("#{@root}/")
      end

      def elapsed(started)
        (Deadheat.now - started).round(1)
      end

      def format_duration(seconds)
        seconds < 60 ? "#{seconds.round(1)} s" : "#{(seconds / 60).floor}m #{(seconds % 60).round.to_s.rjust(2, '0')}s"
      end
    end
  end
end
