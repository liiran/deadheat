module Deadheat
  # Every row of the tables it covers, plus the id counters, taken with the query cache off. A
  # snapshot can be put back: rows deleted and re-inserted with the same ids, counters reset. That's
  # how each try starts from exactly the same data.
  class Snapshot
    BATCH = 200

    attr_reader :rows, :sequences, :tables

    def self.take(schema, tables = schema.tables)
      connection = schema.connection
      rows = ActiveRecord::Base.uncached do
        tables.to_h { |table| [table, connection.select_all("SELECT * FROM #{connection.quote_table_name(table)}").to_a] }
      end
      new(schema, tables, rows, Sequences.read(connection, schema, tables))
    end

    def initialize(schema, tables, rows, sequences)
      @schema = schema
      @tables = tables
      @rows = rows
      @sequences = sequences
    end

    def [](table)
      @rows.fetch(table, [])
    end

    # Put these tables back exactly as they were in this snapshot.
    def restore(tables = @tables)
      tables &= @tables
      return if tables.empty?

      connection = @schema.connection
      ActiveRecord::Base.uncached do
        connection.disable_referential_integrity do
          connection.transaction(requires_new: true) do
            tables.each do |table|
              connection.execute("DELETE FROM #{connection.quote_table_name(table)}")
              insert(connection, table, @rows[table])
            end
          end
        end
        Sequences.write(connection, @sequences, tables)
      end
    end

    private

    def insert(connection, table, rows)
      return if rows.empty?

      names = @schema.column_names(table) & rows.first.keys
      quoted = names.map { |name| connection.quote_column_name(name) }.join(", ")
      rows.each_slice(BATCH) do |batch|
        values = batch.map { |row| "(#{names.map { |name| quote(connection, table, name, row[name]) }.join(', ')})" }
        connection.execute("INSERT INTO #{connection.quote_table_name(table)} (#{quoted}) VALUES #{values.join(', ')}")
      end
    end

    # Values come back from the database in its own text form, so they go back in the same way.
    # Raw bytes (MySQL and SQLite blobs) are written as binary literals.
    def quote(connection, _table, _name, value)
      if value.is_a?(String) && value.encoding == Encoding::BINARY && !value.ascii_only?
        connection.quote(ActiveModel::Type::Binary::Data.new(value))
      else
        connection.quote(value)
      end
    end

    # The next id each table will hand out. Restoring it means a try's new rows get the same ids as
    # the try before, so results can be compared row for row.
    module Sequences
      module_function

      def read(connection, schema, tables)
        case connection.adapter_name
        when /postg/i then read_postgres(connection, tables)
        when /mysql|trilogy/i then read_mysql(connection, tables)
        when /sqlite/i then read_sqlite(connection, schema)
        else {}
        end
      end

      def write(connection, sequences, tables)
        case connection.adapter_name
        when /postg/i
          tables.each do |table|
            name, last, called = sequences[table]
            next unless name

            connection.select_value("SELECT setval(#{connection.quote(name)}, #{Integer(last)}, #{called ? 'true' : 'false'})")
          end
        when /mysql|trilogy/i
          tables.each do |table|
            next_id = sequences[table]
            connection.execute("ALTER TABLE #{connection.quote_table_name(table)} AUTO_INCREMENT = #{Integer(next_id)}") if next_id
          end
        when /sqlite/i
          return unless sequences.key?(:sqlite)

          tables.each do |table|
            connection.execute("DELETE FROM sqlite_sequence WHERE name = #{connection.quote(table)}")
            seq = sequences[:sqlite][table]
            connection.execute("INSERT INTO sqlite_sequence (name, seq) VALUES (#{connection.quote(table)}, #{Integer(seq)})") if seq
          end
        end
      end

      def read_postgres(connection, tables)
        tables.each_with_object({}) do |table, map|
          _, sequence = connection.pk_and_sequence_for(table)
          next unless sequence

          last, called = connection.select_rows("SELECT last_value, is_called FROM #{connection.quote_table_name(sequence)}").first
          map[table] = [sequence.to_s, last, called == true || called == "t"]
        end
      end

      def read_mysql(connection, tables)
        begin
          connection.execute("SET SESSION information_schema_stats_expiry = 0")
        rescue ActiveRecord::StatementInvalid
          nil # MariaDB has no such setting and doesn't cache these numbers
        end
        rows = connection.select_rows(<<~SQL)
          SELECT TABLE_NAME, AUTO_INCREMENT FROM information_schema.TABLES
          WHERE TABLE_SCHEMA = DATABASE() AND AUTO_INCREMENT IS NOT NULL
        SQL
        rows.to_h { |name, next_id| [name, next_id] }.slice(*tables)
      end

      def read_sqlite(connection, _schema)
        exists = connection.select_value("SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'sqlite_sequence'")
        return {} unless exists

        { sqlite: connection.select_rows("SELECT name, seq FROM sqlite_sequence").to_h }
      end
    end
  end
end
