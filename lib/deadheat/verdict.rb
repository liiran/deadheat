module Deadheat
  # Decides what one simultaneous run means by comparing it with the one-at-a-time runs.
  #
  # - ok:        it matches one of the one-at-a-time results exactly.
  # - differs:   the data is right, but a reply differs (say 201 where one at a time gives 422).
  #              Worth knowing, not a failure.
  # - protected: one request was turned away with a conflict (optimistic locking, 409) and the data
  #              is what the other request alone would have left. The app defended itself.
  # - crash:     the data is fine, but a request failed with an error (a 500 for the user).
  # - race:      the data, side effects or `check`s match nothing that can happen one at a time.
  class Verdict
    STATUSES = %i[ok differs protected crash race].freeze

    attr_reader :status, :kind, :title, :lines, :irreversible, :expected, :table

    def self.judge(outcome, serial:, singles:, schema:)
      new(outcome, serial, singles, schema).tap(&:decide)
    end

    def initialize(outcome, serial, singles, schema)
      @outcome = outcome
      @serial = serial
      @singles = singles
      @schema = schema
      @lines = []
      @irreversible = false
    end

    def ok?
      status == :ok
    end

    def decide
      return set(:ok, :ok, "Same result as one at a time", @serial.first) if @serial.any? { |s| @outcome.same_as?(s) }

      if @outcome.failed_checks.empty?
        # Same data as a one-at-a-time run: only the replies differ.
        serial_match = @serial.find { |s| @outcome.same_data_as?(s) }
        return tap { decide_on_replies(serial_match) } if serial_match

        # Same data as if only one actor had run. That's fine only if the others were turned away or
        # failed; if they were all told it worked, a change was silently lost.
        single_match = @singles.find { |s| @outcome.same_data_as?(s) }
        if single_match && @outcome.replies.each_with_index.any? { |reply, i| single_match.replies[i].nil? && (reply.conflict? || reply.failed?) }
          return tap { decide_on_replies(single_match) }
        end
        @lost_to_single = !single_match.nil?
      end
      decide_race(nearest)
      self
    end

    private

    def set(status, kind, title, expected)
      @status = status
      @kind = kind
      @title = title
      @expected = expected
    end

    def decide_on_replies(match)
      replies = @outcome.replies
      names = @outcome.actors
      if replies.any?(&:conflict?) && @singles.include?(match)
        index = replies.index(&:conflict?)
        set(:protected, :protected, "Protected: #{names[index]} was turned away (#{replies[index].error || replies[index].status}) and the data stayed right", match)
      elsif replies.any?(&:failed?)
        index = replies.index(&:failed?)
        error = replies[index].error || "HTTP #{replies[index].status}"
        set(:crash, :crash, "Crashed: #{names[index]} failed with #{error} instead of being handled", match)
      else
        set(:differs, :different_replies, "Different replies: the data is right, but the replies don't match any one-at-a-time run", match)
      end
      @lines = reply_lines(match)
    end

    def decide_race(expected)
      @lines = @outcome.canon.differences(expected.canon)
      effect_lines, @irreversible = @outcome.effects.extra_over(expected.effects)
      @lines.concat(effect_lines)
      @lines.concat(reply_lines(expected))

      failed = @outcome.failed_checks
      if failed.any?
        return set(:race, :check, "Broke the rule “#{failed.first}”", expected)
      end

      duplicate = duplicate_despite_rule(expected)
      if duplicate
        @table = duplicate.last
        return set(:race, :duplicate_rule, duplicate.first, expected)
      end

      # A balance or stock below zero is the most telling sign, so it names the finding even when
      # extra rows were made too (those are still listed underneath).
      negative = @outcome.canon.negative_values(expected.canon).first
      if negative
        t, key, column, value = negative
        return set(:race, :below_zero, "Went below zero: #{t}#{" ##{key}" if key} #{column} ended at #{show(value)}", expected)
      end

      table = more_rows_table(expected)
      if table
        @table = table
        extra = @outcome.canon.tables.keys.select { |t| @outcome.canon.added_count(t) > expected.canon.added_count(t) }
        title = if extra.size > 1
                  "Made twice: #{extra.map { |t| "#{@outcome.canon.added_count(t)} new #{t}" }.join(', ')}, where one at a time there are #{extra.map { |t| expected.canon.added_count(t) }.join(', ')}"
                else
                  have = @outcome.canon.added_count(table)
                  want = expected.canon.added_count(table)
                  "Made twice: #{have} new #{table} where one at a time there #{want == 1 ? 'is' : 'are'} #{want}"
                end
        return set(:race, :made_twice, title, expected)
      end

      lost = lost_update(expected)
      return set(:race, :lost_update, lost, expected) if lost

      return set(:race, :sent_twice, "Sent twice: #{effect_lines.first}", expected) if effect_lines.any?

      if @lost_to_single
        return set(:race, :misleading_reply, "Lost a change: every request was told it worked, but only one of them took effect", expected)
      end

      set(:race, :different, "Different result: two at once left the data in a state one at a time never does", expected)
    end

    # The one-at-a-time result this run is closest to, for explaining the difference.
    def nearest
      @serial.min_by do |candidate|
        @outcome.canon.differences(candidate.canon).size + (@outcome.effects == candidate.effects ? 0 : 1)
      end
    end

    def more_rows_table(expected)
      (@outcome.canon.tables.keys).find { |table| @outcome.canon.added_count(table) > expected.canon.added_count(table) }
    end

    def duplicate_despite_rule(expected)
      @outcome.canon.tables.each_key do |table|
        next unless @outcome.canon.added_count(table) > expected.canon.added_count(table)

        @schema.uniqueness_rules(table).each do |rule|
          have = duplicates(@outcome.after[table], rule)
          next if have.empty? || have.size <= duplicates(expected.after[table], rule).size

          values = rule[:columns].zip(have.first).map { |column, value| Redact.hidden?(column) ? column.to_s : "#{column} “#{show(value)}”" }.join(" and ")
          return ["Duplicate despite a rule: 2 #{table} with the same #{values}, though the model says it must be unique", table]
        end
      end
      nil
    end

    def duplicates(rows, rule)
      groups = rows.group_by do |row|
        rule[:columns].map do |column|
          value = row[column]
          rule[:case_sensitive] == false && value.is_a?(String) ? value.downcase : value
        end
      end
      groups.select { |key, members| members.size > 1 && key.none?(&:nil?) }.keys
    end

    def lost_update(expected)
      @outcome.canon.tables.each do |table, change|
        change.changed.each do |key, columns|
          columns.each do |column, old, new|
            next unless new.is_a?(Numeric) && old.is_a?(Numeric)

            theirs = expected.canon.tables[table]&.changed&.to_h&.dig(key)&.find { |c, *| c == column }
            next unless theirs

            mine_delta = new - old
            their_delta = theirs[2] - theirs[1]
            next unless their_delta.abs > mine_delta.abs

            return "Lost update: #{table} ##{key} #{column} went #{show(old, column)} → #{show(new, column)}, one at a time #{show(theirs[1], column)} → #{show(theirs[2], column)}"
          end
        end
        # A counter in a row this run created (an upsert-style counter that starts at 1).
        theirs = expected.canon.tables[table]
        next unless theirs && theirs.added.size == change.added.size

        change.added.zip(theirs.added).each do |mine, other|
          other = other.to_h
          mine.each do |column, value|
            want = other[column]
            next unless value.is_a?(Numeric) && want.is_a?(Numeric) && value.abs < want.abs

            return "Lost update: a new #{table} row's #{column} is #{show(value, column)}, one at a time #{show(want, column)}"
          end
        end
      end
      nil
    end

    def reply_lines(expected)
      names = @outcome.actors
      @outcome.replies.each_with_index.filter_map do |reply, i|
        theirs = expected.replies[i]
        next if theirs.nil? || reply == theirs

        "#{names[i]} got #{reply} (one at a time: #{theirs})"
      end
    end

    # A value for a message. A column the app hides from its logs shows as [FILTERED].
    def show(value, column = nil)
      value.is_a?(BigDecimal) ? (value.frac.zero? ? value.to_i.to_s : value.to_s("F")) : Redact.value(column, value.to_s)
    end
  end
end
