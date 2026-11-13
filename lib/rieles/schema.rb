module Rieles
  Column = Struct.new(:name, :type) do
    def integer? = type == :integer
    def timestamp? = %w[created_at updated_at].include?(name)
    def default_literal = integer? ? "0" : '""'
    def sql_type = integer? ? "INTEGER NOT NULL DEFAULT 0" : "TEXT NOT NULL DEFAULT ''"
  end

  Table = Struct.new(:name, :columns) do
    def column(name) = columns.find { |c| c.name == name }

    def create_sql
      defs = columns.map { |c| c.name == "id" ? "id INTEGER PRIMARY KEY" : "#{c.name} #{c.sql_type}" }
      "CREATE TABLE IF NOT EXISTS #{name} (#{defs.join(', ')})"
    end
  end

  # Spinel values can't be nil where a String or Integer is expected, so
  # every column is NOT NULL with a default; `null:` options are ignored.
  class Schema
    TYPES = {
      string: :string, text: :string, datetime: :string, date: :string, time: :string,
      integer: :integer, bigint: :integer, references: :integer
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
      columns = [Column.new("id", :integer)]
      body = node.block&.body&.body || []
      body.each do |call|
        fail!(call, "expected t.<type> :name") unless call.is_a?(Prism::CallNode) && call.receiver
        if call.name == :timestamps
          columns << Column.new("created_at", :string) << Column.new("updated_at", :string)
          next
        end
        type = TYPES.fetch(call.name) { fail!(call, "unsupported column type t.#{call.name}") }
        col_args, = Rieles.call_args(call)
        col_name = Rieles.literal(col_args.first).to_s
        col_name += "_id" if call.name == :references
        columns << Column.new(col_name, type)
      end
      @tables[name] = Table.new(name, columns)
    end

    def fail!(node, message)
      raise CompileError, "#{@file}:#{node.location.start_line}: #{message}"
    end
  end
end
