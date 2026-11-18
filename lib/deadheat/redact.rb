# frozen_string_literal: true

module Deadheat
  # Dead Heat shows queries and changed values in its messages, result files and report. Columns the
  # app already hides from its own logs (`config.filter_parameters`, which Rails also applies to
  # Active Record: passwords, tokens, keys…) are hidden here too. Only what is shown changes; the
  # comparison still uses the real values.
  #
  # This is a best effort, like the log filter it follows: it goes by column names, so a secret in a
  # column the app doesn't filter, or in a URL, is shown as it is.
  module Redact
    MASK = "[FILTERED]"
    IDENTIFIER = /[`"\[]?(\w+)[`"\]]?/
    STRING = /'(?:[^'\\]|\\.|'')*'/

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
    # conditions). In order:
    # - `column = 'value'` for a hidden column
    # - the whole VALUES list of an INSERT that has a hidden column in it
    # - if a hidden column is named anywhere else in the statement (`lower(email) = lower('…')`,
    #   `token IN ('…')`), every quoted value in it
    def sql(text)
      text = text.gsub(/(#{IDENTIFIER})(\s*(?:=|<>|!=|LIKE)\s*)(#{STRING}|-?\d+(?:\.\d+)?)/i) do
        whole, name, column, operator = Regexp.last_match.values_at(0, 1, 2, 3)
        hidden?(column) ? "#{name}#{operator}#{MASK}" : whole
      end
      text = text.sub(/\A(INSERT\s+(?:IGNORE\s+)?INTO\s+\S+\s*\(([^)]*)\)\s*VALUES\s*)\(.*\z/im) do
        whole, head, columns = Regexp.last_match.values_at(0, 1, 2)
        columns.scan(/\w+/).any? { |column| hidden?(column) } ? "#{head}(#{MASK})" : whole
      end
      return text unless text.match?(STRING)

      names = text.gsub(STRING, "").gsub(MASK, "").scan(/[A-Za-z_]\w*/).uniq
      names.any? { |name| hidden?(name) } ? text.gsub(STRING, MASK) : text
    end
  end
end
