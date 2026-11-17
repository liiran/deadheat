module Deadheat
  # Turns the query timeline of a failing try into a sentence about what happened, and lays the
  # timeline out for people.
  module Explain
    module_function

    # "Both requests read products before either one wrote to it, …" when the timeline shows that
    # overlap; otherwise a general sentence.
    def why(actors, kind, made: nil)
      overlap = read_write_overlap(actors, prefer: made)
      if overlap
        table, first, second = overlap
        reads = [first, second].map { |a| a[:read].source }.compact.uniq
        where = reads.any? ? " (#{reads.join(', ')})" : ""
        if %i[made_twice duplicate_rule].include?(kind) && table == made
          "Both requests looked in #{table} before either one wrote to it#{where}, so neither saw the other's row and both created one."
        else
          "Both requests read #{table} before either one wrote to it#{where}, so each acted on a value the other was about to change."
        end
      elsif kind == :crash
        "The requests overlapped, and the second one hit an error the code doesn't handle."
      else
        "The requests overlapped in a way that can't happen one at a time."
      end
    end

    # The table both requests read before either wrote to it, or nil.
    def overlap_table(actors)
      read_write_overlap(actors)&.first
    end

    # [table, a, b] where actors a and b both read the table before the other wrote to it. A table
    # that was read and then written by the same request (the guard, like products.stock) comes
    # before the table that only got new rows.
    def read_write_overlap(actors, prefer: nil)
      found = all_overlaps(actors)
      guard = found.find { |table, *| table != prefer }
      guard || found.first
    end

    def all_overlaps(actors)
      result = []
      firsts = actors.map do |actor|
        actor.events.each_with_object({}) do |event, map|
          event.tables.each do |table|
            slot = (map[table] ||= {})
            slot[:read] ||= event if event.kind == :read
            slot[:write] ||= event if event.kind == :write
          end
        end
      end
      tables = firsts.flat_map { |map| map.select { |_, slot| slot[:write] }.keys }.uniq
      tables.each do |table|
        actors.each_index.to_a.combination(2).each do |i, j|
          a = firsts[i][table]
          b = firsts[j][table]
          next unless a && b && a[:read] && b[:read]

          a_write = a[:write]&.done || Float::INFINITY
          b_write = b[:write]&.done || Float::INFINITY
          next unless a[:write] || b[:write]

          result << [table, a, b] if a[:read].done < b_write && b[:read].done < a_write
        end
      end
      result
    end

    # Rows for the two-lane timeline: one per query, in the order the database answered them.
    def timeline(actors)
      start = actors.filter_map(&:t0).min || 0
      actors.flat_map(&:events).sort_by(&:done).map do |event|
        {
          actor: event.actor,
          at_ms: ((event.done - start) * 1000).round(1),
          kind: event.kind.to_s,
          sql: event.sql,
          source: event.source,
          paused_ms: ((event.paused_after || event.paused_before || 0) * 1000).round,
          pause: event.paused_after ? "after" : (event.paused_before ? "before" : nil)
        }
      end
    end
  end
end
