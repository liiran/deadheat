# frozen_string_literal: true

module Deadheat
  # The sweep: no race tests to write. It runs your request and integration tests in two passes.
  #
  # 1. record: every request a test makes is noted (which test, which request, which endpoint) along
  #    with whether it wrote to the database.
  # 2. race: each chosen test is run again. When it reaches the chosen request, that request is sent
  #    twice at the same moment from two copies of the test's session (same cookies, same signed-in
  #    user) and compared with sending it twice one after the other, exactly like a race test. Then
  #    the test is stopped: the rest of it doesn't matter, so its own assertions can't confuse the
  #    result. Every table is put back the way it was before the test.
  #
  # The hooks here are installed only when DEADHEAT_SWEEP is set (by `deadheat sweep`), through the
  # Minitest plugin or `--require deadheat/sweep/rspec`.
  module Sweep
    THREAD_KEY = :deadheat_sweep_test
    WRITES_KEY = :deadheat_sweep_writes

    # One running test.
    class TestRun
      attr_reader :id, :file, :line, :name, :context, :thread, :framework
      attr_accessor :index, :target, :route, :original, :schema, :bypass, :result

      def initialize(id:, file:, line:, name:, context:, framework:, target: nil)
        @id = id
        @file = file
        @line = line
        @name = name
        @context = context
        @framework = framework
        @target = target
        @thread = Thread.current
        @index = 0
        @bypass = false
      end

      def location
        "#{file}:#{line}"
      end
    end

    class << self
      def mode
        ENV["DEADHEAT_SWEEP"]
      end

      def active?
        %w[record race].include?(mode)
      end

      def current
        Thread.current.thread_variable_get(THREAD_KEY)
      end

      # Targets for this process: { test id => the chosen request (index, method, route…) }.
      # The runner sends at most one target per test to each process.
      def targets
        @targets ||= begin
          path = ENV["DEADHEAT_SWEEP_TARGETS"]
          list = path && File.exist?(path) ? JSON.parse(File.read(path)) : []
          list.group_by { |t| t["test"] }.transform_values { |ts| ts.min_by { |t| t["index"] } }
        end
      end

      def install!
        return if @installed || !active?

        @installed = true
        Probe.install!
        ActionDispatch::Integration::Session.prepend(SessionHook)
        Probe.prepend(WriteCounter)
      end

      # Called by the framework hooks at the start and end of every test.
      def begin_test(**details)
        return unless active?

        install!
        run = TestRun.new(**details)
        if mode == "race"
          target = targets[run.id]
          return unless target

          run.target = target["index"]
          run.route = target["route"]
        end
        Thread.current.thread_variable_set(THREAD_KEY, run)
        if mode == "race"
          Writes.clear
          Writes.start
          run.schema = Schema.new(Preflight.database!)
          run.original = Snapshot.take(run.schema)
        end
        run
      end

      def end_test
        run = current
        return unless run

        Thread.current.thread_variable_set(THREAD_KEY, nil)
        run.original&.restore(Writes.tables_in(run.schema))
        Writes.stop if run.original
        run.result
      end

      def target?(id)
        mode == "race" && targets.key?(id)
      end

      def relative(path)
        path.to_s.delete_prefix("./").delete_prefix("#{Dir.pwd}/")
      end

      def connection
        ActiveRecord::Base.respond_to?(:lease_connection) ? ActiveRecord::Base.lease_connection : ActiveRecord::Base.connection
      end

      # A line per request, for the record pass.
      def record(run, session, method, path, kwargs, writes, status)
        out = ENV["DEADHEAT_SWEEP_OUT"]
        return unless out

        request = session.request
        endpoint = session.controller ? "#{session.controller.class.name}##{session.controller.action_name}" : nil
        pattern = request.respond_to?(:route_uri_pattern) ? request.route_uri_pattern : nil
        line = {
          test: run.id, file: run.file, line: run.line, name: run.name, framework: run.framework,
          index: run.index, method: method.to_s.upcase, path: path.to_s.sub(/\?.*/, ""),
          route: pattern&.sub("(.:format)", ""), endpoint: endpoint, writes: writes, status: status,
          signed_in: signed_in?(session)
        }
        File.open(out, "a") { |f| f.puts(line.to_json) }
        record_routes(out)
      end

      def record_routes(out)
        return if @routes_recorded

        @routes_recorded = true
        routes = Rails.application.routes.routes.filter_map do |route|
          verb = route.verb.to_s
          next if verb.empty? || route.internal || (route.app.respond_to?(:engine?) && route.app.engine?)

          endpoint = route.defaults[:controller] && "#{route.defaults[:controller].camelize}Controller##{route.defaults[:action]}"
          { verb: verb, path: route.path.spec.to_s.sub("(.:format)", ""), endpoint: endpoint }
        end
        File.open(out, "a") { |f| f.puts({ routes: routes }.to_json) }
      end

      def signed_in?(session)
        jar = session.send(:_mock_session).cookie_jar
        jar.to_hash.any?
      rescue StandardError
        false
      end

      # Sends the chosen request twice at once from copies of the test's session, then stops the test.
      def race_here(run, session, method, path, kwargs)
        consume_queued_login(run, session)
        cookies = session.send(:_mock_session).cookie_jar.dup
        host = session.host
        https = session.https?
        label = "#{method.to_s.upcase} #{run.route || path.to_s.sub(/\?.*/, '')}"
        payload = kwargs
        result = Race.new(run.context, label, location: run.location, reproduce: reproduce(run)) do |r|
          r.twice("request", cookies: cookies, host: host, https: https) do
            integration_session.process(method, path, **Sweep.fresh(payload))
          end
        end.run
        run.result = result
        saved = Results.save(result, extra: { sweep: { test: run.id, file: run.file, line: run.line, name: run.name, index: run.index, method: method.to_s.upcase, path: path.to_s.sub(/\?.*/, ""), route: run.route } })
        raise Stop, "Dead Heat raced request #{run.index} of this test and stopped it (results: #{saved})"
      end

      def reproduce(run)
        "bin/deadheat sweep #{run.file}"
      end

      # Devise's test sign-in waits for "the next request" in any thread. If it's still waiting, send
      # it to this session now, so both copies carry the login.
      def consume_queued_login(run, session)
        return unless defined?(Warden) && Warden.respond_to?(:_on_next_request) && Warden._on_next_request.any?

        run.bypass = true
        session.process(:get, Ping::PATH)
      ensure
        run.bypass = false
      end

      # A copy of the request's arguments for one run. Uploaded files are opened again, because two
      # threads can't read one file handle at once.
      def fresh(value)
        case value
        when Hash then value.transform_values { |v| fresh(v) }
        when Array then value.map { |v| fresh(v) }
        when ->(v) { defined?(Rack::Test::UploadedFile) && v.is_a?(Rack::Test::UploadedFile) }
          Rack::Test::UploadedFile.new(value.path, value.content_type, value.instance_variable_get(:@binary) || false, original_filename: value.original_filename)
        else value
        end
      end
    end

    # Counts writes per thread, so the record pass knows which requests changed data.
    module WriteCounter
      def finish(name, id, payload)
        counter = Thread.current.thread_variable_get(WRITES_KEY)
        counter[0] += 1 if counter && !SQL.internal?(payload) && SQL.kind(payload[:sql].to_s) == :write
        super
      end
    end

    # Wraps every request a test makes.
    module SessionHook
      def process(method, path, **kwargs)
        run = Sweep.current
        return super if run.nil? || run.bypass || Thread.current != run.thread

        run.index += 1
        case Sweep.mode
        when "record"
          counter = [0]
          Thread.current.thread_variable_set(WRITES_KEY, counter)
          begin
            status = super
          ensure
            Thread.current.thread_variable_set(WRITES_KEY, nil)
          end
          Sweep.record(run, self, method, path, kwargs, counter[0], status)
          status
        when "race"
          return super unless run.index == run.target

          Writes.track { Sweep.race_here(run, self, method, path, kwargs) }
        else
          super
        end
      end
    end
  end
end

module Deadheat
  module Sweep
    class << self
      # Used by the regression tests the sweep writes: race one request of one test again, in its own
      # process, and say whether it passed. Returns { passed:, message:, status: }.
      def recheck(test:, file:, index:, route: nil, framework: "minitest")
        # A sweep runs the app's tests itself, these included. It's already checking every request,
        # so a regression test has nothing to add there (and would start a sweep inside a sweep).
        return { passed: true, status: "skipped", message: "Skipped while bin/deadheat sweep runs the tests." } if active?

        require "deadheat/sweep/runner"
        root = defined?(Rails) && Rails.root ? Rails.root.to_s : Dir.pwd
        run_id = "recheck-#{Time.now.utc.strftime('%Y%m%d-%H%M%S')}-#{SecureRandom.hex(2)}"
        result = Runner.new(framework: framework, out: StringIO.new, root: root, write_tests: false, run_id: run_id).recheck(test: test, file: file, index: index, route: route)
        return { passed: false, status: "unchecked", message: "Dead Heat couldn't reach request #{index} of #{test}. Has the test changed? Run bin/deadheat sweep #{file} to look again." } if result[:status] == "unchecked"

        { passed: result[:passed], status: result[:status], message: result[:message] }
      end
    end
  end
end
