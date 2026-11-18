module Deadheat
  # Runs actors on worker threads, each with its own database connection: all at once from a common
  # starting line, or one after another.
  #
  # The workers live for a whole race and are reused for every run, like Puma's threads. Apps keep
  # things per thread on that assumption (Mastodon keeps a Redis connection in Thread.current for the
  # thread's life), and a fresh thread per run would strand one of those every time.
  class Racer
    # One long-lived thread that runs one job at a time.
    class Worker
      def initialize(index)
        @jobs = Queue.new
        @thread = Thread.new do
          Thread.current.report_on_exception = false
          Thread.current.name = "deadheat worker #{index + 1}"
          while (job = @jobs.pop)
            job.call
          end
        end
      end

      def run(&job)
        done = Concurrent::Event.new
        @jobs << lambda {
          begin
            job.call
          ensure
            done.set
          end
        }
        done
      end

      def stop
        @jobs << nil
        @thread.join(1) || @thread.kill
      end

      def kill
        @thread.kill
      end
    end

    def initialize(count, timeout:, lock_timeout:)
      @workers = Array.new(count) { |i| Worker.new(i) }
      @timeout = timeout
      @lock_timeout = lock_timeout
    end

    def together(actors)
      barrier = Concurrent::CyclicBarrier.new(actors.size)
      events = actors.each_with_index.map { |actor, i| @workers[i].run { perform(actor, barrier) } }
      wait(events, actors)
    end

    def one_by_one(actors, indexes)
      actors.zip(indexes).each do |actor, i|
        wait([@workers[i].run { perform(actor, nil) }], [actor], [i])
      end
    end

    def stop
      @workers.each(&:stop)
    end

    private

    def perform(actor, barrier)
      Probe.with_actor(actor) do
        begin
          limit_lock_waits
          barrier&.wait(@timeout)
          delay = actor.schedule&.start_delay
          sleep(delay) if delay
          actor.t0 = Deadheat.now
          actor.response = actor.block.call
        rescue Exception => e # rubocop:disable Lint/RescueException -- assertions and app errors are results here
          actor.error = e
        ensure
          actor.finished = Deadheat.now
          release_connections
        end
      end
    end

    def wait(events, actors, indexes = (0...actors.size).to_a)
      deadline = Deadheat.now + @timeout
      events.each_with_index do |event, i|
        next if event.wait([deadline - Deadheat.now, 0.01].max)

        # A worker stuck past the time limit is replaced, so the next run starts clean.
        slot = indexes[i]
        @workers[slot].kill
        @workers[slot] = Worker.new(slot)
        raise Hung, "#{actors[i].name} didn't finish within #{@timeout.round} s (stuck waiting for a lock or an external call?)"
      end
    end

    # A request stuck behind a lock should fail after a few seconds instead of hanging the test run.
    def limit_lock_waits
      connection = ActiveRecord::Base.respond_to?(:lease_connection) ? ActiveRecord::Base.lease_connection : ActiveRecord::Base.connection
      case connection.adapter_name
      when /postg/i then connection.execute("SET lock_timeout = '#{Integer(@lock_timeout)}s'")
      when /mysql|trilogy/i then connection.execute("SET SESSION innodb_lock_wait_timeout = #{Integer(@lock_timeout)}")
      end
    end

    def release_connections
      handler = ActiveRecord::Base.connection_handler
      handler.clear_active_connections!(:all)
    rescue ArgumentError
      handler.clear_active_connections!
    end
  end
end
