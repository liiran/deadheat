module Deadheat
  # Text for the terminal and test failures.
  module Format
    module_function

    def result(result)
      out = []
      broken = result.broken_tries
      head = if broken.positive?
               "Race: “#{result.name}” broke in #{broken} of #{result.tries} tries"
             else
               "No race found in #{result.tries} tries: “#{result.name}”"
             end
      out << "#{head} (seed #{result.seed}, #{result.database})"
      result.findings.each { |finding| out.concat(finding(finding, result)) }
      result.warnings.each { |warning| out << "" << "  Note: #{warning}" }
      if broken.positive? && result.reproduce
        out << "" << "  Reproduce: #{result.reproduce}"
      end
      out.join("\n")
    end

    def finding(finding, result)
      out = [""]
      label = { race: "✗", crash: "!", protected: "✓", differs: "~", hung: "!" }[finding.status]
      times = finding.count == 1 ? "1 try" : "#{finding.count} tries"
      out << "  #{label} #{finding.title}#{'  [irreversible]' if finding.irreversible} (#{times})"
      finding.lines.each { |line| out << "      #{line}" }
      return out if %i[protected differs].include?(finding.status)

      out << "" << "    Why: #{finding.why}"
      out << "" << "    What happened in try #{finding.try} (#{finding.pauses}):"
      out.concat(timeline(finding.timeline).map { |line| "      #{line}" })
      out << "" << "    Fix:"
      finding.fixes.each { |fix| out << "      • #{fix}" }
      out
    end

    def timeline(rows, limit: 40)
      names = rows.map { |row| row[:actor].to_s }
      width = names.map(&:length).max.to_i
      lines = rows.first(limit).map do |row|
        pause = row[:pause] ? "  (waited #{row[:paused_ms]} ms #{row[:pause]})" : ""
        source = row[:source] ? "  #{row[:source]}" : ""
        format("%7.1f ms  %-#{width}s │ %s%s%s", row[:at_ms], row[:actor], row[:sql], source, pause)
      end
      lines << "      … #{rows.size - limit} more queries" if rows.size > limit
      lines
    end
  end
end
