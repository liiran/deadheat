# frozen_string_literal: true

module Deadheat
  # Dead Heat shows queries and changed values in its messages, result files and report. Columns the
  # app already hides from its own logs (`config.filter_parameters`, which Rails also applies to
  # Active Record: passwords, tokens, keys…) are hidden here too. Only what is shown changes; the
  # comparison still uses the real values.
  #
  # This is a best effort, like the log filter it follows: it goes by column and parameter names, so
  # a secret in a column the app doesn't filter, or in the path of a URL, is shown as it is.
  module Redact
    MASK = "[FILTERED]"
    NUMBER = /0x\h+|-?\d+(?:\.\d+)?/i
    NAME = /[`"\[]?\b(?<column>\w++)[`"\]]?/

    # The patterns for values written into a statement. They depend on the database: MySQL reads \'
    # inside a string as a quote, PostgreSQL and SQLite read the backslash as an ordinary character
    # (except in E'…' strings). Reading it the wrong way would move where strings begin and end.
    Patterns = Struct.new(:quoted, :comparison, :list, :between)

    module_function

    def hidden?(column)
      return false if column.nil?

      filters = defined?(ActiveRecord::Base) && ActiveRecord::Base.respond_to?(:filter_attributes) ? ActiveRecord::Base.filter_attributes : []
      return false if filters.empty?

      if @filters != filters
        @filters = filters.dup
        @filter = ActiveSupport::ParameterFilter.new(filters, mask: MASK)
        @hidden = {}
      end
      name = column.to_s
      @hidden.fetch(name) { @hidden[name] = @filter.filter_param(name, "value") != "value" }
    end

    def value(column, text)
      hidden?(column) ? MASK : text
    end

    # For values written into the SQL itself (MySQL without prepared statements, hand-written
    # conditions). For a hidden column, in order:
    # - `column = value`, and the other comparisons (<>, <, >=, LIKE…)
    # - `column IN (…)` and `column BETWEEN … AND …`
    # - the whole VALUES list of an INSERT that has a hidden column in it
    # - if a hidden column is still named anywhere else (`lower(email) = lower('…')`, a JSON key
    #   like `data->>'token'`), every quoted value in the statement
    def sql(text)
      return text unless names_in(text).any? { |name| hidden?(name) }

      patterns = patterns_for(backslash_escapes?)
      text = text.gsub(patterns.comparison) { hide(Regexp.last_match) }
      text = text.gsub(patterns.list) { hide(Regexp.last_match, "(#{MASK})") }
      text = text.gsub(patterns.between) { hide(Regexp.last_match) }
      text = text.sub(/\A(INSERT\s+(?:IGNORE\s+)?INTO\s+\S+\s*\(([^)]*)\)\s*VALUES\s*)\(.*\z/im) do
        whole, head, columns = Regexp.last_match.values_at(0, 1, 2)
        columns.scan(/\w+/).any? { |column| hidden?(column) } ? "#{head}(#{MASK})" : whole
      end
      return text unless text.match?(patterns.quoted)

      json_keys = text.scan(/->>?\s*'(\w+)'/).flatten
      names = names_in(text.gsub(patterns.quoted, "").gsub(MASK, "")) + json_keys
      names.any? { |name| hidden?(name) } ? text.gsub(patterns.quoted, MASK) : text
    end

    # A path with a query string (a redirect's target): the values of parameters the app hides from
    # its logs are hidden here too. `/done?token=abc&page=2` becomes `/done?token=[FILTERED]&page=2`.
    def url(path)
      return path unless path.is_a?(String) && path.include?("?")

      head, query = path.split("?", 2)
      query, fragment = query.split("#", 2)
      pairs = query.split("&").map do |pair|
        key, value = pair.split("=", 2)
        value && hidden?(key.to_s[/[^\[\]]+\]?\z/].to_s.delete("]")) ? "#{key}=#{MASK}" : pair
      end
      "#{head}?#{pairs.join('&')}#{"##{fragment}" if fragment}"
    end

    def hide(match, shown = MASK)
      hidden?(match[:column]) ? "#{match[:name]}#{match[:operator]}#{shown}" : match[0]
    end

    # Words that could be column names. Capped in length, so a long value (a file's bytes written
    # as hex) isn't read as one.
    def names_in(text)
      text.scan(/\b[A-Za-z_]\w{0,63}\b/).uniq
    end

    def backslash_escapes?
      ActiveRecord::Base.connection_db_config.adapter.to_s.match?(/mysql|trilogy|maria/i)
    rescue StandardError
      false
    end

    def patterns_for(backslash)
      @patterns ||= {}
      @patterns[backslash] ||= build(backslash)
    end

    def build(backslash)
      escaped = /'(?:[^'\\]|\\.|'')*'/
      plain = /'(?:[^']|'')*'/
      string = backslash ? /(?:(?<!\w)[ENXB])?#{escaped}/i : /(?<!\w)E#{escaped}|(?:(?<!\w)[NXB])?#{plain}/i
      dollar = /\$(?<tag>\w*)\$.*?\$\k<tag>\$/m
      quoted = /#{string}|#{dollar}/
      # "text" in double quotes is a value on MySQL and SQLite; `"table"."column"` is left alone.
      value = /#{string}|#{dollar}|"(?:[^"\\]|\\.|"")*"(?!\s*\.)|#{NUMBER}/
      Patterns.new(
        quoted,
        /(?<name>#{NAME})(?<operator>\s*(?:<>|!=|<=|>=|=|<|>|(?:NOT\s+)?I?LIKE\b)\s*)(?<value>#{value})/im,
        /(?<name>#{NAME})(?<operator>\s+(?:NOT\s+)?IN\s*)\((?<values>[^()]*)\)/im,
        /(?<name>#{NAME})(?<operator>\s+(?:NOT\s+)?BETWEEN\s+)(?<low>#{string}|#{NUMBER})\s+AND\s+(?<high>#{string}|#{NUMBER})/im
      )
    end
  end
end
