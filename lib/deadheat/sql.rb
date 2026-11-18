# frozen_string_literal: true

module Deadheat
  # Reads just enough of a SQL statement to know whether it reads or writes, and which tables.
  module SQL
    NAME = /[`"\[]?(?:\w+[`"\]]?\.[`"\[]?)?(\w+)[`"\]]?/
    COMMENTS = %r{/\*.*?\*/}m
    WRITE_TABLE = /\A(?:INSERT\s+(?:(?:OR\s+)?(?:IGNORE|REPLACE|ROLLBACK|ABORT|FAIL)\s+)?INTO|REPLACE\s+INTO|UPDATE(?:\s+ONLY)?|DELETE\s+FROM(?:\s+ONLY)?|MERGE\s+INTO|TRUNCATE(?:\s+TABLE)?(?:\s+ONLY)?)\s+#{NAME}/i
    # A statement that starts with WITH can still write: WITH x AS (…) INSERT INTO orders …
    WRITE_INSIDE = /\b(?:INSERT\s+INTO|UPDATE|DELETE\s+FROM)\s+#{NAME}/i
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
      when /\A(?:INSERT|UPDATE|DELETE|REPLACE|MERGE|TRUNCATE)\b/i then :write
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
        match ? [match[1]] : text.scan(WRITE_INSIDE).flatten.uniq
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

    # The statement with its bound values written in, for showing to a person. Values of columns the
    # app hides from its logs are hidden here too (see Redact).
    def readable(payload, limit: 160)
      sql = Redact.sql(strip(payload[:sql]).gsub(/\s+/, " "))
      binds = payload[:type_casted_binds]
      binds = binds.call if binds.respond_to?(:call)
      if binds.is_a?(Array) && binds.any?
        names = bind_names(payload[:binds])
        values = binds.each_with_index.map { |value, i| Redact.hidden?(names[i]) ? Redact::MASK : show_value(value) }
        index = -1
        sql = sql.gsub(/\$(\d+)|\?/) { |token| token.start_with?("$") ? (values[token[1..].to_i - 1] || token) : (values[index += 1] || token) }
      end
      sql.length > limit ? "#{sql[0, limit - 1]}…" : sql
    end

    # The column each bound value belongs to, when Rails says (it usually does).
    def bind_names(binds)
      Array(binds).map do |bind|
        bind = bind.first if bind.is_a?(Array)
        bind.respond_to?(:name) ? bind.name : nil
      end
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
