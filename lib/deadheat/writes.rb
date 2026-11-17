module Deadheat
  # Which tables were written while Dead Heat was watching, in any thread. Only these need to be put
  # back the way they were.
  module Writes
    @tables = Concurrent::Set.new
    @depth = Concurrent::AtomicFixnum.new(0)

    class << self
      def track
        start
        yield
      ensure
        stop
      end

      def start
        @depth.increment
      end

      def stop
        @depth.decrement if @depth.value.positive?
      end

      def tracking?
        @depth.value.positive?
      end

      def note(payload)
        return if SQL.internal?(payload)

        sql = payload[:sql].to_s
        return unless SQL.kind(sql) == :write

        SQL.tables(sql, :write).each { |table| @tables << table }
      end

      def tables
        @tables.to_a
      end

      def clear
        @tables.clear
      end
    end
  end
end
