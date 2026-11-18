module Deadheat
  # What a run changed in the database, written so that two runs that did the same thing come out
  # equal even though new rows got different ids and timestamps.
  #
  # - Rows that already existed are matched by primary key; only their changed columns count.
  # - New rows are compared by content. Their ids are dropped, timestamps count only as "set" or
  #   "empty", and columns that point at other new rows point at a label made from that row's content.
  # - Ignored and noisy columns (ones that differ even between two identical one-at-a-time runs, such
  #   as random tokens) are left out.
  class Canon
    TableChange = Struct.new(:added, :removed, :changed, keyword_init: true) do
      def empty?
        added.empty? && removed.empty? && changed.empty?
      end
    end

    TIME_IN_TEXT = /\d{4}-\d{2}-\d{2}[ T]\d{2}:\d{2}(?::\d{2}(?:\.\d+)?)?(?:\s?(?:Z|UTC|[+-]\d{2}:?\d{2}))?/

    attr_reader :tables, :new_ids, :added_rows, :after

    # ignore: a Set of "table.column" and "table.*" strings.
    def self.build(schema, before, after, ignore: Set.new)
      new(schema, before, after, ignore).tap(&:compute)
    end

    def initialize(schema, before, after, ignore)
      @schema = schema
      @before = before
      @after = after
      @ignore = ignore
      @config = Deadheat.config
      @tables = {}
      @new_ids = Set.new
      @new_by_table = Hash.new { |h, k| h[k] = {} }
      @added_rows = {}
      @labels = {}
    end

    def ==(other)
      other.is_a?(Canon) && tables == other.tables
    end
    alias eql? ==

    def hash
      tables.hash
    end

    def empty?
      tables.empty?
    end

    def compute
      # Only tables the "after" snapshot covers. It holds just the tables that were written, and a
      # table it leaves out didn't change (reading it as empty would call every row deleted).
      table_names = @after.tables
      changes = table_names.to_h { |table| [table, raw_change(table)] }
      changes.each_value { |change| change[:added].each { |row| remember_new(change[:table], row) } }
      changes.each { |table, change| label_rows(table, change[:added]) }
      changes.each do |table, change|
        next if compared_table?(table) == false

        result = TableChange.new(
          added: change[:added].map { |row| canonical_row(table, row) }.sort_by(&:to_s),
          removed: change[:removed].map { |row| key_of(table, row) }.sort_by(&:to_s),
          changed: change[:changed].filter_map { |old, new| changed_columns(table, old, new) }.sort_by(&:to_s)
        )
        @tables[table] = result unless result.empty?
        @added_rows[table] = change[:added] if change[:added].any?
      end
      @tables.freeze
      self
    end

    # Plain sentences saying how this run differs from another one. "expected" is the other run.
    def differences(expected)
      lines = []
      (tables.keys | expected.tables.keys).sort.each do |table|
        mine = tables[table] || TableChange.new(added: [], removed: [], changed: [])
        theirs = expected.tables[table] || TableChange.new(added: [], removed: [], changed: [])
        if mine.added.size != theirs.added.size
          lines << "#{table}: #{count(mine.added.size, 'new row')} (one at a time: #{theirs.added.size})"
        elsif mine.added != theirs.added
          lines << "#{table}: the new rows have different values#{row_difference(mine.added, theirs.added)}"
        end
        if mine.removed.size != theirs.removed.size
          lines << "#{table}: #{count(mine.removed.size, 'row')} deleted (one at a time: #{theirs.removed.size})"
        end
        lines.concat(changed_differences(table, mine.changed, theirs.changed))
      end
      lines
    end

    # Numeric values that ended below zero where the expected run kept them at zero or above:
    # [table, key, column, value]. Columns that are negative by design (a ranking score, say) stay
    # negative one at a time too, so they never count.
    def negative_values(expected = nil)
      found = []
      tables.each do |table, change|
        change.changed.each do |key, columns|
          columns.each do |column, old, new|
            next unless new.is_a?(Numeric) && new.negative?
            next if old.is_a?(Numeric) && old.negative?
            next if expected && expected.final_value(table, key, column).then { |v| v.is_a?(Numeric) && v.negative? }

            found << [table, key, column, new]
          end
        end
        change.added.each do |row|
          row.each do |column, value|
            next unless value.is_a?(Numeric) && value.negative?
            next if expected && expected.added_values(table, column).any? { |v| v.is_a?(Numeric) && v.negative? }

            found << [table, nil, column, value]
          end
        end
      end
      found
    end

    # The value a changed row's column ended with (nil if this run didn't change it).
    def final_value(table, key, column)
      tables[table]&.changed&.to_h&.dig(key)&.find { |name, *| name == column }&.last
    end

    def added_values(table, column)
      (tables[table]&.added || []).filter_map { |row| row.to_h[column] }
    end

    def added_count(table)
      tables[table]&.added&.size.to_i
    end

    # For the results file. Values of columns the app hides from its logs are hidden (see Redact).
    def to_h
      hide = ->(column, value) { value.nil? ? nil : Redact.value(column, value) }
      tables.transform_values do |change|
        {
          added: change.added.map { |row| row.map { |column, value| [column, hide.call(column, value)] } },
          removed: change.removed.map { |row| row.is_a?(Array) ? row.map { |column, value| [column, hide.call(column, value)] } : row },
          changed: change.changed.map { |key, columns| [key, columns.map { |column, old, new| [column, hide.call(column, old), hide.call(column, new)] }] }
        }
      end
    end

    private

    def compared_table?(table)
      !@config.ignored_table?(table) && !@ignore.include?("#{table}.*")
    end

    def compared_column?(table, column)
      !@config.ignored_column?(table, column) && !@ignore.include?("#{table}.#{column}")
    end

    def raw_change(table)
      before = @before[table]
      after = @after[table]
      keys = @schema.key_columns(table)
      if keys.empty?
        multiset_change(table, before, after)
      else
        old = before.to_h { |row| [row.values_at(*keys), row] }
        new = after.to_h { |row| [row.values_at(*keys), row] }
        {
          table: table,
          added: new.reject { |key, _| old.key?(key) }.values,
          removed: old.reject { |key, _| new.key?(key) }.values,
          changed: new.filter_map { |key, row| [old[key], row] if old.key?(key) && old[key] != row }
        }
      end
    end

    # Tables without a primary key (plain join tables): rows are compared as a whole.
    def multiset_change(table, before, after)
      counts = Hash.new(0)
      before.each { |row| counts[row] -= 1 }
      after.each { |row| counts[row] += 1 }
      added = counts.flat_map { |row, n| n.positive? ? [row] * n : [] }
      removed = counts.flat_map { |row, n| n.negative? ? [row] * -n : [] }
      { table: table, added: added, removed: removed, changed: [] }
    end

    def surrogate_key(table)
      keys = @schema.key_columns(table)
      return nil unless keys.size == 1

      column = @schema.columns(table).find { |c| c.name == keys.first }
      return nil unless column

      keys.first if %i[integer bigint].include?(column.type) || column.sql_type.to_s.match?(/uuid|uniqueidentifier/i)
    end

    def remember_new(table, row)
      key = surrogate_key(table)
      return unless key

      id = row[key]
      @new_by_table[table][id.to_s] = row
      @new_ids << id.to_s
    end

    def new_row?(table, id)
      !id.nil? && @new_by_table.key?(table) && @new_by_table[table].key?(id.to_s)
    end

    # A short label for each new row, from its own content, so references to it can be compared.
    def label_rows(table, rows)
      rows.each do |row|
        content = canonical_row(table, row, with_labels: false)
        @labels[[table, row[surrogate_key(table)].to_s]] = Digest::SHA1.hexdigest(content.to_s)[0, 8] if surrogate_key(table)
      end
    end

    def canonical_row(table, row, with_labels: true)
      own = surrogate_key(table)
      row.filter_map do |column, value|
        next if column == own || !compared_column?(table, column)

        [column, canonical_value(table, column, value, row, own_id: own && row[own], with_labels: with_labels)]
      end.sort_by(&:first)
    end

    def changed_columns(table, old, new)
      columns = new.filter_map do |column, value|
        next unless compared_column?(table, column)

        before = canonical_value(table, column, old[column], old)
        after = canonical_value(table, column, value, new)
        [column, before, after] unless before == after
      end
      [key_of(table, new), columns.sort_by(&:first)] if columns.any?
    end

    def canonical_value(table, column, value, row, own_id: nil, with_labels: true)
      return nil if value.nil?
      return "(set)" if @schema.time_column?(table, column)

      target = @schema.references.dig(table, column)
      target = row[target.last].to_s.then { |type| table_for_type(type) } if target.is_a?(Array)
      if target && new_row?(target, value)
        label = with_labels ? @labels[[target, value.to_s]] : nil
        return ["new #{target}", label].compact.join(" ")
      end

      plain(table, column, value, own_id)
    end

    def plain(table, column, value, own_id)
      case value
      when String
        return "(#{value.bytesize} bytes #{Digest::SHA1.hexdigest(value)[0, 8]})" if value.encoding == Encoding::BINARY && !value.ascii_only?
        return BigDecimal(value) if @schema.numeric_column?(table, column) && value.match?(/\A-?\d+(\.\d+)?\z/)

        # A time written into text ("used at 2026-11-17 04:06:41") differs between runs just like a
        # timestamp column does, so it's compared the same way: present, not its value.
        value = value.gsub(TIME_IN_TEXT, "(time)")
        return value.gsub(/(?<!\d)#{Regexp.escape(own_id.to_s)}(?!\d)/, "‹own id›") if own_id.is_a?(Integer) && own_id > 9

        value
      when BigDecimal, Integer, Float then BigDecimal(value.to_s)
      when Time, DateTime, Date then "(set)"
      else value
      end
    end

    def table_for_type(type)
      model = type.safe_constantize
      model.table_name if model.is_a?(Class) && model < ActiveRecord::Base
    rescue StandardError
      nil
    end

    def key_of(table, row)
      keys = @schema.key_columns(table)
      keys.empty? ? canonical_row(table, row) : row.values_at(*keys).map(&:to_s).join("/")
    end

    def count(number, noun)
      "#{number} #{number == 1 ? noun : noun.pluralize}"
    end

    def row_difference(mine, theirs)
      a = (mine - theirs).first
      b = (theirs - mine).first
      return "" unless a && b

      column = a.zip(b).find { |x, y| x != y }&.first&.first
      column ? " (#{column}: #{show(a.to_h[column], column)} vs. #{show(b.to_h[column], column)} one at a time)" : ""
    end

    def changed_differences(table, mine, theirs)
      mine_map = mine.to_h
      theirs_map = theirs.to_h
      (mine_map.keys | theirs_map.keys).sort_by(&:to_s).flat_map do |key|
        a = (mine_map[key] || []).to_h { |column, old, new| [column, [old, new]] }
        b = (theirs_map[key] || []).to_h { |column, old, new| [column, [old, new]] }
        (a.keys | b.keys).sort.filter_map do |column|
          next if a[column] == b[column]

          now = a[column] ? "#{show(a[column][0], column)} → #{show(a[column][1], column)}" : "unchanged"
          expected = b[column] ? "#{show(b[column][0], column)} → #{show(b[column][1], column)}" : "unchanged"
          "#{table} ##{key} #{column}: #{now} (one at a time: #{expected})"
        end
      end
    end

    # A value for a message. A column the app hides from its logs shows as [FILTERED].
    def show(value, column = nil)
      case value
      when nil then "empty"
      when BigDecimal then value.frac.zero? ? value.to_i.to_s : value.to_s("F")
      else Redact.value(column, value.to_s)
      end
    end
  end
end
