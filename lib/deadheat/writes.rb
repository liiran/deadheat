module Deadheat
  # Which tables were written while a race was running, in any thread. Between tries only these are
  # put back the way they were.
  module Writes
    @tables = Concurrent::Set.new
    @depth = Concurrent::AtomicFixnum.new(0)

    class << self
      def track
        @depth.increment
        yield
      ensure
        @depth.decrement
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
