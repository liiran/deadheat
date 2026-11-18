# frozen_string_literal: true

module Deadheat
  # Which tables were written while Dead Heat was watching, in any thread. Only these need to be put
  # back the way they were.
  module Writes
    @tables = Concurrent::Set.new
    @depth = Concurrent::AtomicFixnum.new(0)
    @unreadable = Concurrent::AtomicBoolean.new(false)
    @elsewhere = Concurrent::Set.new

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

        note_other_database(payload)
        found = SQL.tables(sql, :write)
        # A write whose table can't be read from the statement: play safe and treat every table as written.
        @unreadable.make_true if found.empty?
        found.each { |table| @tables << table }
      end

      def tables
        @tables.to_a
      end

      # The tables to restore and compare: the ones written, plus the ones the database changes by
      # itself when they are (cascading foreign keys). Every table, if some write couldn't be read.
      def tables_in(schema)
        @unreadable.true? ? schema.tables : schema.with_cascades(tables)
      end

      # Names of other databases (an app with `connects_to`) that were written to. Dead Heat only
      # restores and compares the main one.
      def other_databases
        @elsewhere.to_a
      end

      def clear
        @tables.clear
        @elsewhere.clear
        @unreadable.make_false
      end

      private

      def note_other_database(payload)
        pool = payload[:connection]&.pool
        return if pool.nil? || !defined?(ActiveRecord::Base) || pool.equal?(ActiveRecord::Base.connection_pool)

        @elsewhere << pool.db_config.name.to_s
      rescue StandardError
        nil
      end
    end
  end
end
