module Deadheat
  # Runs actors in their own threads, each with its own database connection: all at once from a
  # common starting line, or one after another.
  module Racer
    module_function

    def together(actors, timeout:, lock_timeout:)
      barrier = Concurrent::CyclicBarrier.new(actors.size)
      threads = actors.map { |actor| start(actor, barrier, timeout, lock_timeout) }
      wait(threads, actors, timeout)
    end

    def one_by_one(actors, timeout:, lock_timeout:)
      actors.each do |actor|
        wait([start(actor, nil, timeout, lock_timeout)], [actor], timeout)
      end
    end

    def start(actor, barrier, timeout, lock_timeout)
      Thread.new do
        Thread.current.report_on_exception = false
        Thread.current.name = "deadheat #{actor.name}"
        Probe.with_actor(actor) do
          begin
            limit_lock_waits(lock_timeout)
            barrier&.wait(timeout)
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
    end

    def wait(threads, actors, timeout)
      deadline = Deadheat.now + timeout
      threads.each_with_index do |thread, i|
        next if thread.join([deadline - Deadheat.now, 0.01].max)

        thread.kill
        raise Hung, "#{actors[i].name} didn't finish within #{timeout.round} s (stuck waiting for a lock or an external call?)"
      end
    end

    # A request stuck behind a lock should fail after a few seconds instead of hanging the test run.
    def limit_lock_waits(seconds)
      connection = ActiveRecord::Base.respond_to?(:lease_connection) ? ActiveRecord::Base.lease_connection : ActiveRecord::Base.connection
      case connection.adapter_name
      when /postg/i then connection.execute("SET lock_timeout = '#{Integer(seconds)}s'")
      when /mysql|trilogy/i then connection.execute("SET SESSION innodb_lock_wait_timeout = #{Integer(seconds)}")
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
