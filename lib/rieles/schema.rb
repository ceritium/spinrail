module Rieles
  # null: true columns hold nil. Tep::SQLite reads NULL as "" and can't bind
  # it, so reads select "col IS NULL" too and writes go through NULLIF with
  # a sentinel (Rieles::NULL_STR / NULL_INT).
  Column = Struct.new(:name, :type, :default, :null) do
    def integer? = type == :integer
    def boolean? = type == :boolean
    def float? = type == :float
    def string? = type == :string
    def timestamp? = %w[created_at updated_at].include?(name)

    def default_literal
      return default.inspect unless default.nil?
      return "nil" if null
      { integer: "0", boolean: "false", float: "0.0", string: '""' }.fetch(type)
    end

    def sql_type
      sql_default = default.nil? ? nil : (boolean? ? (default ? 1 : 0) : default)
      if null
        base = { integer: "INTEGER", boolean: "INTEGER", float: "REAL", string: "TEXT" }.fetch(type)
        return sql_default.nil? ? base : "#{base} DEFAULT #{string? ? "'#{sql_default.to_s.gsub("'", "''")}'" : sql_default}"
      end
      case type
      when :integer, :boolean then "INTEGER NOT NULL DEFAULT #{sql_default || 0}"
      when :float then "REAL NOT NULL DEFAULT #{sql_default || 0.0}"
      else "TEXT NOT NULL DEFAULT '#{sql_default.to_s.gsub("'", "''")}'"
      end
    end

    def placeholder
      return "?" unless null
      integer? || boolean? ? "NULLIF(?, -9007199254740991)" : "NULLIF(?, char(1))"
    end

    # Ruby expression reading column i of the current row; null_flag is the
    # index of its "IS NULL" column.
    def read(i, null_flag = nil)
      value = read_value(i)
      null_flag ? "(db.col_int(#{null_flag}) == 1 ? nil : #{value})" : value
    end

    def read_value(i)
      case type
      when :integer then "db.col_int(#{i})"
      when :boolean then "db.col_int(#{i}) == 1"
      when :float then "db.col_str(#{i}).to_f"
      else "db.col_str(#{i})"
      end
    end

    def bind(i, value)
      return bind_value(i, value) unless null
      case type
      when :integer then "db.bind_int(#{i}, #{value}.nil? ? Rieles::NULL_INT : #{value})"
      when :boolean then "db.bind_int(#{i}, #{value}.nil? ? Rieles::NULL_INT : (#{value} ? 1 : 0))"
      when :float then "db.bind_str(#{i}, #{value}.nil? ? Rieles::NULL_STR : #{value}.to_s)"
      else "db.bind_str(#{i}, #{value}.nil? ? Rieles::NULL_STR : #{value})"
      end
    end

    def bind_value(i, value)
      case type
      when :integer then "db.bind_int(#{i}, #{value})"
      when :boolean then "db.bind_int(#{i}, #{value} ? 1 : 0)"
      when :float then "db.bind_str(#{i}, #{value}.to_s)"
      else "db.bind_str(#{i}, #{value})"
      end
    end
  end

  Table = Struct.new(:name, :columns) do
    def column(name) = columns.find { |c| c.name == name }

    def add_column_sql(column) = "ALTER TABLE #{name} ADD COLUMN #{column.name} #{column.sql_type}"

    def create_sql
      defs = columns.map { |c| c.name == "id" ? "id INTEGER PRIMARY KEY" : "#{c.name} #{c.sql_type}" }
      "CREATE TABLE IF NOT EXISTS #{name} (#{defs.join(', ')})"
    end
  end

  # Columns are NOT NULL with a default unless declared `null: true`.
  class Schema
    TYPES = {
      string: :string, text: :string, datetime: :string, date: :string, time: :string,
      integer: :integer, bigint: :integer, references: :integer, belongs_to: :integer,
      boolean: :boolean, float: :float, decimal: :float
    }.freeze

    attr_reader :tables

    def initialize(file)
      @file = file
      @tables = {}
      walk(Rieles.parse(File.read(file), file))
    end

    def table(name) = @tables[name]

    private

    def walk(node)
      if node.is_a?(Prism::CallNode) && node.receiver.nil? && node.name == :create_table
        create_table(node)
      else
        node.compact_child_nodes.each { |child| walk(child) }
      end
    end

    def create_table(node)
      args, = Rieles.call_args(node)
      name = Rieles.literal(args.first).to_s
      columns = [Column.new("id", :integer, nil, false)]
      body = node.block&.body&.body || []
      body.each do |call|
        fail!(call, "expected t.<type> :name") unless call.is_a?(Prism::CallNode) && call.receiver
        if call.name == :timestamps
          columns << Column.new("created_at", :string, nil, false) << Column.new("updated_at", :string, nil, false)
          next
        end
        type = TYPES.fetch(call.name) { fail!(call, "unsupported column type t.#{call.name}") }
        col_args, kw = Rieles.call_args(call)
        col_name = Rieles.literal(col_args.first).to_s
        col_name += "_id" if %i[references belongs_to].include?(call.name)
        default = kw[:default] ? Rieles.literal(kw[:default]) : nil
        null = kw[:null] ? Rieles.literal(kw[:null]) == true : false
        columns << Column.new(col_name, type, default, null)
      end
      @tables[name] = Table.new(name, columns)
    end

    def fail!(node, message)
      raise CompileError, "#{@file}:#{node.location.start_line}: #{message}"
    end
  end
end
