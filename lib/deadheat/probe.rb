module Deadheat
  # The one listener on Rails' `sql.active_record` event. It does nothing outside a race. Inside a
  # racing thread it hands each query to that thread's actor (which records it and may pause), and in
  # every thread it notes which tables were written, so only those need restoring between tries.
  #
  # Rails calls `start` just before a query goes to the database and `finish` right after, in the
  # thread that sent it, so a pause here really does hold that request at that point.
  class Probe
    THREAD_KEY = :deadheat_actor

    class << self
      def install!
        return if @subscriber

        @subscriber = ActiveSupport::Notifications.subscribe("sql.active_record", new)
      end

      def current_actor
        Thread.current.thread_variable_get(THREAD_KEY)
      end

      def with_actor(actor)
        Thread.current.thread_variable_set(THREAD_KEY, actor)
        yield
      ensure
        Thread.current.thread_variable_set(THREAD_KEY, nil)
      end
    end

    def start(_name, _id, payload)
      Probe.current_actor&.query_started(payload)
    rescue Exception => e # rubocop:disable Lint/RescueException -- never let our listener break the app's query
      Deadheat.internal_error(e)
    end

    def finish(_name, _id, payload)
      Writes.note(payload) if Writes.tracking?
      Probe.current_actor&.query_finished(payload)
    rescue Exception => e # rubocop:disable Lint/RescueException
      Deadheat.internal_error(e)
    end
  end
end
