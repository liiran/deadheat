require "prism"
require "active_support"
require "active_support/core_ext/string/inflections"
require "json"
require "fileutils"

module Deadheat
  # Reads the app's code (no database, nothing runs) and lists suspects: places that read a value,
  # decide, and write it back without a lock. These are guesses, not findings. The sweep checks whether
  # each one really races; the scan tells it where to look first and helps explain what it finds.
  module Scan
    Suspect = Struct.new(:file, :line, :rule, :where, :message, :fix, keyword_init: true) do
      def to_h = super

      def location = "#{file}:#{line}"
    end

    RULES = {
      check_then_act: "check-then-act",
      ruby_math: "math in Ruby",
      look_then_create: "look-then-create",
      unique_without_index: "uniqueness without index",
      lock_outside_transaction: "lock outside a transaction"
    }.freeze

    FIXES = {
      check_then_act: "Lock the row while deciding (`record.with_lock { … }`), or make the write the check: `Model.where(id: id, used_at: nil).update_all(used_at: Time.current) == 1`.",
      ruby_math: "Let the database do the arithmetic: `Model.update_counters(id, column: 1)`, `increment!`, or `update_all(\"column = column - ?\", n)`.",
      look_then_create: "Add a unique index on those columns and use `create_or_find_by`, or rescue `ActiveRecord::RecordNotUnique`.",
      unique_without_index: "Add a unique index that matches the validation; the validation alone can't stop two requests at once.",
      lock_outside_transaction: "`lock!` only holds the lock inside a transaction. Use `with_lock { … }`."
    }.freeze

    # Methods that change a record.
    WRITES = %i[
      update update! save save! update_attribute update_column update_columns increment! decrement!
      toggle! destroy destroy! delete touch increment decrement
    ].freeze
    CREATES = %i[create create! insert insert! new build].freeze
    COUNTS = %i[count size length exists? any? none? empty? sum].freeze
    FINDS = %i[find_by find_by! first take last].freeze
    STATE_CHECKS = %i[valid? invalid? persisted? new_record? destroyed? changed? errors frozen? readonly? previously_new_record? nil? present? blank? empty? any? none? []].freeze
    # Writes that are safe on their own: the database does the arithmetic.
    ATOMIC = %i[increment! decrement! update_counters increment_counter decrement_counter upsert upsert_all].freeze

    module_function

    def start(argv, out: $stdout)
      root = Dir.pwd
      paths = argv.empty? ? default_paths(root) : argv
      suspects = run(root: root, paths: paths)
      print(suspects, out: out, root: root)
      dir = File.join(root, "tmp/deadheat")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "scan.json"), JSON.pretty_generate(suspects: suspects.map(&:to_h)))
      0
    end

    def default_paths(root)
      %w[app lib].map { |dir| File.join(root, dir) }.select { |dir| Dir.exist?(dir) }
    end

    def run(root:, paths: default_paths(root))
      schema = SchemaIndexes.load(root)
      files = paths.flat_map { |path| File.directory?(path) ? Dir[File.join(path, "**/*.rb")] : [path] }.sort
      files.flat_map do |file|
        relative = file.delete_prefix("#{root}/")
        Checker.new(relative, File.read(file), schema).suspects
      rescue StandardError => e
        warn "Dead Heat couldn't read #{relative}: #{e.message}"
        []
      end
    end

    def print(suspects, out:, root:)
      files = suspects.map(&:file).uniq
      out.puts "Dead Heat scan: #{suspects.size} suspect#{'s' unless suspects.size == 1} in #{files.size} file#{'s' unless files.size == 1}"
      out.puts "(Read from the code only. `bin/deadheat sweep` checks whether they really race.)"
      suspects.group_by(&:file).each do |file, list|
        out.puts "", file
        list.sort_by(&:line).each do |suspect|
          out.puts format("  %4d  %-26s %s", suspect.line, RULES.fetch(suspect.rule), suspect.message)
        end
      end
      out.puts "", "Nothing looks racy." if suspects.empty?
    end

    # Unique indexes from db/schema.rb (or db/structure.sql): { table => [[columns], …] }.
    module SchemaIndexes
      module_function

      def load(root)
        schema = File.join(root, "db/schema.rb")
        structure = File.join(root, "db/structure.sql")
        if File.exist?(schema)
          from_schema_rb(File.read(schema))
        elsif File.exist?(structure)
          from_structure_sql(File.read(structure))
        else
          {}
        end
      end

      def from_schema_rb(source)
        indexes = Hash.new { |h, k| h[k] = [] }
        walk(Prism.parse(source).value) do |node|
          next unless node.is_a?(Prism::CallNode)

          case node.name
          when :create_table
            table = string_arg(node, 0)
            next unless table && node.block

            walk(node.block) do |inner|
              next unless inner.is_a?(Prism::CallNode) && inner.name == :index && unique?(inner)

              columns = columns_arg(inner, 0)
              indexes[table] << columns if columns
            end
          when :add_index
            table = string_arg(node, 0)
            columns = columns_arg(node, 1)
            indexes[table] << columns if table && columns && unique?(node)
          end
        end
        indexes.default_proc = nil
        indexes
      end

      def from_structure_sql(sql)
        indexes = Hash.new { |h, k| h[k] = [] }
        sql.scan(/CREATE UNIQUE INDEX \S+ ON (?:\w+\.)?"?(\w+)"? (?:USING \w+ )?\(([^)]+)\)/i) do |table, columns|
          indexes[table] << columns.split(",").map { |c| c.strip.delete('"`') }
        end
        indexes.default_proc = nil
        indexes
      end

      def walk(node, &block)
        return unless node

        yield node
        node.compact_child_nodes.each { |child| walk(child, &block) }
      end

      def string_arg(node, index)
        arg = node.arguments&.arguments&.[](index)
        case arg
        when Prism::StringNode then arg.unescaped
        when Prism::SymbolNode then arg.unescaped
        end
      end

      def columns_arg(node, index)
        arg = node.arguments&.arguments&.[](index)
        case arg
        when Prism::StringNode, Prism::SymbolNode then [arg.unescaped]
        when Prism::ArrayNode then arg.elements.filter_map { |e| e.unescaped if e.respond_to?(:unescaped) }
        end
      end

      def unique?(node)
        hash = node.arguments&.arguments&.find { |a| a.is_a?(Prism::KeywordHashNode) || a.is_a?(Prism::HashNode) }
        hash&.elements&.any? { |e| e.is_a?(Prism::AssocNode) && e.key.respond_to?(:unescaped) && e.key.unescaped == "unique" && e.value.is_a?(Prism::TrueNode) } || false
      end
    end

    # Looks at one file.
    class Checker
      def initialize(file, source, indexes)
        @file = file
        @source = source
        @indexes = indexes
        @suspects = []
        @scope = []
      end

      def suspects
        tree = Prism.parse(@source).value
        visit_scope(tree)
        @suspects.uniq { |s| [s.line, s.rule] }
      end

      private

      def visit_scope(node)
        return unless node

        case node
        when Prism::ClassNode, Prism::ModuleNode
          @scope.push(constant_name(node.constant_path))
          check_model(node) if node.is_a?(Prism::ClassNode)
          node.compact_child_nodes.each { |child| visit_scope(child) }
          @scope.pop
        when Prism::DefNode
          check_method(node)
        else
          node.compact_child_nodes.each { |child| visit_scope(child) }
        end
      end

      def where(method_name = nil)
        name = @scope.join("::")
        method_name ? "#{name}##{method_name}" : name
      end

      def add(rule, line, message, method_name)
        @suspects << Suspect.new(file: @file, line: line, rule: rule, where: where(method_name), message: message, fix: FIXES.fetch(rule))
      end

      # ---- inside one method -------------------------------------------------------------------

      def check_method(defn)
        body = defn.body
        return unless body

        @locked = locked_variables(body)
        @assigned = assigned_lookups(body)
        checks = []
        writes = []
        walk_with_locks(body) do |node, in_lock|
          case node
          when Prism::IfNode, Prism::UnlessNode
            reads_in(node.predicate).each { |read| checks << read.merge(in_lock: in_lock) }
          when Prism::CallNode
            write = write_of(node)
            writes << write.merge(in_lock: in_lock) if write
            ruby_math(node, defn) unless in_lock
            look_then_create_call(node, defn)
            lock_outside_transaction(node, defn)
          when Prism::CallOperatorWriteNode
            if variable(node.receiver) && !in_lock
              add(:ruby_math, node.location.start_line, "`#{variable(node.receiver)}.#{node.read_name} #{node.binary_operator}=` reads the value in Ruby and writes it back, so two requests at once can lose one change.", defn.name)
            end
          when Prism::OrNode
            look_then_create_or(node, defn)
          end
        end

        reported = Set.new
        checks.each do |check|
          next if check[:in_lock] || (check[:var] && @locked.include?(check[:var]))

          write = writes.find do |w|
            next false if w[:line] <= check[:line] || w[:in_lock] || w[:atomic_guard]

            (check[:var] && w[:vars].include?(check[:var])) || (check[:model] && w[:models]&.include?(check[:model]))
          end
          next unless write && reported.add?([check[:var] || check[:model], write[:line]])

          what = check[:count] ? "`#{check[:text]}` is counted" : "`#{check[:text]}` is checked"
          add(:check_then_act, check[:line], "#{what} on line #{check[:line]}, then #{write[:what]} on line #{write[:line]}, with no lock in between. Two requests can both pass the check.", defn.name)
        end
      end

      # Yields every node in the method with whether it sits inside a with_lock (or lock!-ed) block.
      def walk_with_locks(node, in_lock = false, &block)
        return unless node
        return if node.is_a?(Prism::DefNode)

        yield node, in_lock
        lock_here = node.is_a?(Prism::CallNode) && node.name == :with_lock
        node.compact_child_nodes.each do |child|
          walk_with_locks(child, in_lock || (lock_here && child.equal?(node.block)), &block)
        end
      end

      # Local variables holding a count or lookup on a model: { "taken" => { model: "Ticket", … } }.
      def assigned_lookups(body)
        found = {}
        walk(body) do |node|
          next unless node.is_a?(Prism::LocalVariableWriteNode) && node.value.is_a?(Prism::CallNode)

          kind, root = root_of(node.value)
          names = chain_names(node.value)
          next unless kind == :const && names.any? { |name| COUNTS.include?(name) || FINDS.include?(name) || name == :where }
          next if names.include?(:lock)

          found[node.name.to_s] = { model: root, text: node.value.slice, count: names.any? { |name| COUNTS.include?(name) } }
        end
        found
      end

      # Variables loaded with a lock (`Model.lock.find`, `x.lock!`) count as protected.
      def locked_variables(body)
        locked = Set.new
        walk(body) do |node|
          if node.is_a?(Prism::LocalVariableWriteNode) || node.is_a?(Prism::InstanceVariableWriteNode)
            locked << node.name.to_s if chain_names(node.value).include?(:lock)
          elsif node.is_a?(Prism::CallNode) && node.name == :lock! && variable(node.receiver)
            locked << variable(node.receiver)
          end
        end
        locked
      end

      # Attribute reads and counts in a condition: `product.stock`, `event.tickets.count`. A condition
      # that is itself a guarded write (`if Model.where(…).update_all(…) == 1`) is the safe pattern,
      # so it has no reads to report.
      def reads_in(predicate)
        found = []
        guarded = false
        walk(predicate) { |node| guarded ||= node.is_a?(Prism::CallNode) && (node.name == :update_all || ATOMIC.include?(node.name)) }
        return found if guarded

        walk(predicate) do |node|
          # A variable that holds a count or lookup from earlier: `taken = Ticket.where(…).count`.
          if node.is_a?(Prism::LocalVariableReadNode) && (held = @assigned[node.name.to_s])
            found << { var: nil, model: held[:model], line: node.location.start_line, text: "#{node.name} = #{held[:text]}", count: held[:count] }
            next
          end
          next unless node.is_a?(Prism::CallNode)

          kind, root = root_of(node)
          names = chain_names(node).reverse
          next unless root && names.any? && names.none? { |name| name.to_s.end_with?("!", "=") || WRITES.include?(name) }
          next if names == [:id]
          # `record.valid?`, `record.persisted?`: the record's own state, not data another request writes.
          next if kind == :var && STATE_CHECKS.include?(names.first)

          count = names.any? { |name| COUNTS.include?(name) }
          if kind == :var
            found << { var: root, line: node.location.start_line, text: node.slice, count: count }
          elsif names.any? { |name| COUNTS.include?(name) || FINDS.include?(name) || name == :where }
            found << { var: nil, model: root, line: node.location.start_line, text: node.slice, count: count }
          end
        end
        found.uniq { |read| [read[:var], read[:line]] }
      end

      # A call that changes the record held in a variable, or creates a row that points at it.
      def write_of(node)
        var = variable(node.receiver)
        if var && WRITES.include?(node.name)
          return { vars: [var], line: node.location.start_line, what: "`#{var}` is changed (`#{node.name}`)" }
        end
        if var && node.name.to_s.end_with?("=") && node.name != :[]=
          return { vars: [var], line: node.location.start_line, what: "`#{var}.#{node.name.to_s.chomp('=')}` is set" }
        end

        chain = chain_names(node)
        constant_receiver = node.receiver.is_a?(Prism::ConstantReadNode) || node.receiver.is_a?(Prism::ConstantPathNode)
        # `SomeError.new` isn't a row; on a class only create/insert write one. `.new`/`.build` count
        # on an association (`event.tickets.build`), which is then saved.
        creates_row = constant_receiver ? %i[create create! insert insert!].include?(node.name) : association?(node.receiver)
        if CREATES.include?(node.name) && creates_row
          vars = argument_variables(node) + [variable(root_receiver(node))].compact
          constant = constant_name(root_receiver(node))
          model = constant || node.receiver.slice
          article = model.to_s.match?(/\A[AEIOU]/i) ? "an" : "a"
          if vars.any? || constant
            return { vars: vars.uniq, models: [constant].compact, line: node.location.start_line, what: "#{article} #{model} is created" }
          end
        end
        if node.name == :update_all
          return { vars: [], line: node.location.start_line, what: "rows are updated", atomic_guard: chain.include?(:where) }
        end

        nil
      end

      def ruby_math(node, defn)
        return unless %i[update update! update_columns update_column update_attribute assign_attributes update_all].include?(node.name)

        var = variable(node.receiver)
        hash = node.arguments&.arguments&.find { |a| a.is_a?(Prism::KeywordHashNode) || a.is_a?(Prism::HashNode) }
        pairs = hash ? hash.elements.grep(Prism::AssocNode) : []
        if %i[update_column update_attribute].include?(node.name) && node.arguments&.arguments&.size == 2
          key, value = node.arguments.arguments
          pairs = [Struct.new(:key, :value).new(key, value)]
        end
        pairs.each do |pair|
          key = pair.key.respond_to?(:unescaped) ? pair.key.unescaped : nil
          value = pair.value
          next unless key && value.is_a?(Prism::CallNode) && %i[+ -].include?(value.name)

          read = value.receiver
          read_var = read.is_a?(Prism::CallNode) ? variable(read.receiver) : nil
          next unless read.is_a?(Prism::CallNode) && read.name.to_s == key && read_var

          next if var && read_var != var && node.name != :update_all

          add(:ruby_math, node.location.start_line, "`#{value.slice}` is worked out in Ruby and saved, so two requests at once both start from the same `#{key}` and one change is lost.", defn.name)
        end
      end

      def look_then_create_or(node, defn)
        left = node.left
        right = node.right
        return unless left.is_a?(Prism::CallNode) && right.is_a?(Prism::CallNode)
        return unless FINDS.include?(left.name) && CREATES.include?(right.name)

        model = constant_name(root_receiver(left))
        columns = keyword_keys(left)
        return if model && unique_index?(model, columns)

        add(:look_then_create, node.location.start_line, "`#{left.slice}` looks for a row, then `#{right.name}` makes one if it's missing. Two requests can both find nothing and both create one#{index_note(model, columns)}.", defn.name)
      end

      def look_then_create_call(node, defn)
        case node.name
        when :first_or_create, :first_or_create!
          add(:look_then_create, node.location.start_line, "`#{node.name}` looks for a row, then creates one; two requests at once can both create it.", defn.name)
        when :find_or_create_by, :find_or_create_by!, :find_or_initialize_by
          model = constant_name(root_receiver(node)) || (association?(node.receiver) ? nil : node.receiver&.slice)
          columns = keyword_keys(node)
          return if model && unique_index?(model, columns)

          add(:look_then_create, node.location.start_line, "`#{node.name}` without a unique index on #{columns.join(', ')} can make two rows when two requests arrive at once#{index_note(model, columns)}.", defn.name)
        when :first_or_initialize
          # Model.where(a: …, b: …).first_or_initialize, then save: a new row unless one exists.
          where = node.receiver
          model = constant_name(root_receiver(node))
          columns = where.is_a?(Prism::CallNode) && where.name == :where ? keyword_keys(where) : []
          return if model && columns.any? && unique_index?(model, columns)

          add(:look_then_create, node.location.start_line, "`#{node.slice}` looks for a row and starts a new one if it's missing; two requests at once can both save a new one#{index_note(model, columns)}.", defn.name)
        end
      end

      def lock_outside_transaction(node, defn)
        return unless node.name == :lock! && variable(node.receiver)

        inside = false
        # A lock! is only meaningful inside a transaction block in the same method.
        walk(defn.body) do |candidate|
          next unless candidate.is_a?(Prism::CallNode) && %i[transaction with_lock].include?(candidate.name) && candidate.block

          walk(candidate.block) { |inner| inside = true if inner.equal?(node) }
        end
        add(:lock_outside_transaction, node.location.start_line, "`#{node.slice}` outside a transaction releases the lock right away.", defn.name) unless inside
      end

      # ---- models ------------------------------------------------------------------------------

      def check_model(klass)
        name = where
        table = table_for(name, klass)
        return unless klass.superclass && klass.superclass.slice.match?(/ApplicationRecord|ActiveRecord::Base/)

        walk(klass.body) do |node|
          next unless node.is_a?(Prism::CallNode) && node.receiver.nil?

          rules = uniqueness_rules(node)
          rules.each do |columns|
            next if unique_index_on_table?(table, columns)

            add(:unique_without_index, node.location.start_line, "`validates #{columns.first}, uniqueness` has no unique index on #{table}(#{columns.join(', ')}), so two requests at once can both pass it.", nil)
          end
        end
      end

      def uniqueness_rules(node)
        args = node.arguments&.arguments || []
        case node.name
        when :validates
          options = args.find { |a| a.is_a?(Prism::KeywordHashNode) }
          uniqueness = options&.elements&.find { |e| e.is_a?(Prism::AssocNode) && e.key.respond_to?(:unescaped) && e.key.unescaped == "uniqueness" }
          return [] unless uniqueness && !uniqueness.value.is_a?(Prism::FalseNode)

          scope = scope_columns(uniqueness.value)
          args.grep(Prism::SymbolNode).map { |attr| [attr.unescaped, *scope] }
        when :validates_uniqueness_of
          options = args.find { |a| a.is_a?(Prism::KeywordHashNode) }
          scope = options ? scope_columns(options) : []
          args.grep(Prism::SymbolNode).map { |attr| [attr.unescaped, *scope] }
        else
          []
        end
      end

      def scope_columns(value)
        return [] unless value.respond_to?(:elements)

        scope = value.elements.find { |e| e.is_a?(Prism::AssocNode) && e.key.respond_to?(:unescaped) && e.key.unescaped == "scope" }
        return [] unless scope

        case scope.value
        when Prism::SymbolNode then [scope.value.unescaped]
        when Prism::ArrayNode then scope.value.elements.filter_map { |e| e.unescaped if e.respond_to?(:unescaped) }
        else []
        end
      end

      def table_for(name, klass)
        explicit = nil
        walk(klass.body) do |node|
          next unless node.is_a?(Prism::CallNode) && node.name == :table_name= && node.arguments&.arguments&.first.is_a?(Prism::StringNode)

          explicit = node.arguments.arguments.first.unescaped
        end
        explicit || name.split("::").last.tableize
      end

      def unique_index?(model, columns)
        unique_index_on_table?(model.split("::").last.tableize, columns)
      end

      # A unique index covers a rule when the index's columns are all among the rule's columns (an
      # index on fewer columns is even stricter). `user` and `user_id` are the same column here.
      def unique_index_on_table?(table, columns)
        wanted = columns.map { |c| c.to_s.delete_suffix("_id") }
        (@indexes[table] || []).any? do |index|
          index.map { |c| c.to_s.delete_suffix("_id") }.all? { |c| wanted.include?(c) }
        end
      end

      def index_note(model, columns)
        return "" unless model && columns.any?

        " (#{model.split('::').last.tableize} has no unique index on #{columns.join(', ')})"
      end

      # ---- small helpers -----------------------------------------------------------------------

      def walk(node, &block)
        return unless node

        yield node
        node.compact_child_nodes.each { |child| walk(child, &block) }
      end

      def variable(node)
        case node
        when Prism::LocalVariableReadNode then node.name.to_s
        when Prism::InstanceVariableReadNode then node.name.to_s
        end
      end

      # `event.tickets.count` => ["event", :tickets, :count]; a constant root gives its name.
      def chain_of(node)
        parts = []
        current = node
        while current.is_a?(Prism::CallNode)
          parts.unshift(current.name)
          current = current.receiver
        end
        root = variable(current) || constant_name(current)
        root ? [root, *parts] : parts
      end

      # [:var, "product"] or [:const, "Ticket"] for the start of a call chain, or nil.
      def root_of(node)
        root = root_receiver(node)
        if (name = variable(root)) then [:var, name]
        elsif (name = constant_name(root)) then [:const, name]
        end
      end

      def chain_names(node)
        names = []
        current = node
        while current.is_a?(Prism::CallNode)
          names << current.name
          current = current.receiver
        end
        names
      end

      def root_receiver(node)
        current = node
        current = current.receiver while current.is_a?(Prism::CallNode) && current.receiver
        current
      end

      def association?(node)
        node.is_a?(Prism::CallNode) && variable(node.receiver) && node.arguments.nil?
      end

      def argument_variables(node)
        vars = []
        walk(node.arguments) do |arg|
          name = variable(arg)
          vars << name if name
        end
        vars
      end

      def keyword_keys(node)
        hash = node.arguments&.arguments&.find { |a| a.is_a?(Prism::KeywordHashNode) || a.is_a?(Prism::HashNode) }
        hash ? hash.elements.grep(Prism::AssocNode).filter_map { |e| e.key.unescaped if e.key.respond_to?(:unescaped) } : []
      end

      def constant_name(node)
        case node
        when Prism::ConstantReadNode then node.name.to_s
        when Prism::ConstantPathNode then node.slice.delete_prefix("::")
        end
      end
    end
  end
end
