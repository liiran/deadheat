module Deadheat
  # Reads just enough of a SQL statement to know whether it reads or writes, and which tables.
  module SQL
    NAME = /[`"\[]?(?:\w+[`"\]]?\.[`"\[]?)?(\w+)[`"\]]?/
    COMMENTS = %r{/\*.*?\*/}m
    WRITE_TABLE = /\A(?:INSERT\s+(?:IGNORE\s+)?INTO|REPLACE\s+INTO|UPDATE|DELETE\s+FROM)\s+#{NAME}/i
    READ_TABLES = /\b(?:FROM|JOIN)\s+#{NAME}/i
    LOCKING = /\bFOR\s+(?:NO\s+KEY\s+)?(?:UPDATE|SHARE)\b|\bLOCK\s+IN\s+SHARE\s+MODE\b/i
    INTERNAL_NAMES = %w[SCHEMA EXPLAIN].freeze

    module_function

    def strip(sql)
      sql.to_s.gsub(COMMENTS, " ").strip
    end

    # :read, :write, :transaction or :other
    def kind(sql)
      text = strip(sql)
      case text
      when /\A(?:INSERT|UPDATE|DELETE|REPLACE|MERGE)\b/i then :write
      when /\AWITH\b/i then text.match?(/\b(?:INSERT\s+INTO|UPDATE\s+\S+\s+SET|DELETE\s+FROM)\b/i) ? :write : :read
      when /\A(?:SELECT|VALUES|TABLE)\b/i then :read
      when /\A(?:BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE|START\s+TRANSACTION)\b/i then :transaction
      else :other
      end
    end

    def tables(sql, kind = kind(sql))
      text = strip(sql)
      case kind
      when :write
        match = text.match(WRITE_TABLE)
        match ? [match[1]] : []
      when :read
        text.scan(READ_TABLES).flatten.uniq - %w[SELECT select]
      else
        []
      end
    end

    def locking?(sql)
      sql.to_s.match?(LOCKING)
    end

    # Queries Rails sends for itself (loading the schema, EXPLAIN) are never part of a race.
    def internal?(payload)
      INTERNAL_NAMES.include?(payload[:name]) || payload[:cached] || payload[:async]
    end

    # The statement with its bound values written in, for showing to a person.
    def readable(payload, limit: 160)
      sql = strip(payload[:sql]).gsub(/\s+/, " ")
      binds = payload[:type_casted_binds]
      binds = binds.call if binds.respond_to?(:call)
      if binds.is_a?(Array) && binds.any?
        values = binds.map { |value| show_value(value) }
        index = -1
        sql = sql.gsub(/\$(\d+)|\?/) { |token| token.start_with?("$") ? (values[token[1..].to_i - 1] || token) : (values[index += 1] || token) }
      end
      sql.length > limit ? "#{sql[0, limit - 1]}…" : sql
    end

    def show_value(value)
      case value
      when nil then "NULL"
      when Numeric, true, false then value.to_s
      else
        text = value.to_s
        text = "#{text[0, 40]}…" if text.length > 40
        "'#{text}'"
      end
    end
  end
end
