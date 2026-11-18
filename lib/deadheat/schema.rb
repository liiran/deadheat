module Deadheat
  # What Dead Heat needs to know about the database: tables, primary keys, column types, and which
  # columns point at rows in other tables (foreign keys, belongs_to and polymorphic associations).
  class Schema
    INTERNAL = %w[schema_migrations ar_internal_metadata sqlite_sequence].freeze

    attr_reader :connection, :tables

    def initialize(connection)
      @connection = connection
      @tables = connection.tables.sort - INTERNAL
      @columns = {}
      @primary_keys = {}
      @references = nil
    end

    def adapter
      connection.adapter_name
    end

    def columns(table)
      @columns[table] ||= connection.columns(table).reject { |column| column.respond_to?(:virtual?) && column.virtual? }
    end

    def column_names(table)
      columns(table).map(&:name)
    end

    def primary_key(table)
      @primary_keys.fetch(table) { @primary_keys[table] = connection.primary_key(table) }
    end

    # The primary key as a list of column names ([] when the table has none).
    def key_columns(table)
      Array(primary_key(table)).map(&:to_s)
    end

    def time_column?(table, name)
      column = columns(table).find { |c| c.name == name }
      column && %i[datetime timestamp time date].include?(column.type) || false
    end

    def numeric_column?(table, name)
      column = columns(table).find { |c| c.name == name }
      column && %i[integer decimal float bigint].include?(column.type) || false
    end

    def binary_column?(table, name)
      column = columns(table).find { |c| c.name == name }
      column && column.type == :binary || false
    end

    # { table => { column => target } } where target is a table name, or [:polymorphic, type_column].
    def references
      @references ||= build_references
    end

    # The given tables plus every table the database changes on its own when one of them is written:
    # foreign keys with ON DELETE or ON UPDATE CASCADE / SET NULL, followed all the way down. Those
    # changes never appear as a statement, so they'd otherwise be neither restored nor compared.
    def with_cascades(names)
      found = names.to_a & tables
      queue = found.dup
      until queue.empty?
        cascades_from.fetch(queue.shift, []).each do |child|
          next if found.include?(child)

          found << child
          queue << child
        end
      end
      found
    end

    # Models by table, for uniqueness rules and readable names.
    def models
      @models ||= ActiveRecord::Base.descendants.reject(&:abstract_class?).each_with_object({}) do |model, map|
        table = model.table_name
        map[table] ||= model if table && !model.name.to_s.start_with?("HABTM_")
      rescue StandardError
        next
      end
    end

    def model_for(table)
      models[table]
    end

    # { [columns], scope_columns, case_sensitive } for every `validates uniqueness` rule on the table.
    def uniqueness_rules(table)
      model = model_for(table)
      return [] unless model

      model.validators.grep(ActiveRecord::Validations::UniquenessValidator).flat_map do |validator|
        scope = Array(validator.options[:scope]).map(&:to_s)
        validator.attributes.map do |attribute|
          column = model.attribute_alias?(attribute) ? model.attribute_alias(attribute) : attribute.to_s
          column = model.reflect_on_association(attribute)&.foreign_key&.to_s || column
          { columns: [column, *scope], case_sensitive: validator.options.fetch(:case_sensitive, true), conditions: validator.options[:conditions] }
        end
      end
    rescue StandardError
      []
    end

    private

    # { parent table => [tables with a cascading foreign key to it] }
    def cascades_from
      @cascades_from ||= tables.each_with_object(Hash.new { |hash, key| hash[key] = [] }) do |table, map|
        next unless connection.respond_to?(:foreign_keys)

        connection.foreign_keys(table).each do |fk|
          actions = [fk.on_delete, fk.on_update].compact.map(&:to_sym)
          map[fk.to_table.to_s] << table if (actions & %i[cascade nullify]).any? && !map[fk.to_table.to_s].include?(table)
        end
      rescue StandardError
        next
      end
    end

    def build_references
      map = Hash.new { |hash, key| hash[key] = {} }
      tables.each do |table|
        if connection.respond_to?(:foreign_keys)
          connection.foreign_keys(table).each { |fk| map[table][fk.column.to_s] = fk.to_table.to_s }
        end
      rescue StandardError
        next
      end
      models.each do |table, model|
        model.reflect_on_all_associations(:belongs_to).each do |reflection|
          column = reflection.foreign_key.to_s
          map[table][column] ||= reflection.polymorphic? ? [:polymorphic, reflection.foreign_type.to_s] : reflection.klass.table_name
        rescue StandardError
          next
        end
      end
      map.default_proc = nil
      map
    end
  end
end
