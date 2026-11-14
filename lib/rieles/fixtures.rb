require "yaml"
require "zlib"

module Rieles
  # test/fixtures/<table>.yml, as in Rails: labels get stable ids
  # (CRC32, like ActiveRecord's), `author: ana` sets author_id, and missing
  # columns take their schema default. Loaded as SQL when the server boots.
  module Fixtures
    Row = Struct.new(:attributes) do
      def id = attributes["id"]
      def [](name) = attributes[name.to_s]
      def method_missing(name, *) = attributes.key?(name.to_s) ? attributes[name.to_s] : super
      def respond_to_missing?(name, priv = false) = attributes.key?(name.to_s) || super
    end

    module_function

    def identify(label) = Zlib.crc32(label.to_s) % (2**30 - 1)

    def rows(app)
      @rows ||= {}
      @rows[app] ||= begin
        migrations = Migrations.new(File.join(app, "db/migrate"))
        schema = migrations.any? ? Schema.from_migrations(migrations) : Schema.new(File.join(app, "db/schema.rb"))
        Dir[File.join(app, "test/fixtures/*.yml")].sort.to_h do |file|
          table_name = File.basename(file, ".yml")
          table = schema.table(table_name) or raise "test/fixtures/#{table_name}.yml: no such table"
          data = YAML.safe_load_file(file) || {}
          [table_name, data.to_h { |label, attrs| [label.to_s, Row.new(row(table, label, attrs || {}))] }]
        end
      end
    end

    def row(table, label, attrs)
      now = Time.now.strftime("%Y-%m-%d %H:%M:%S")
      values = { "id" => identify(label) }
      attrs.each do |key, value|
        key = key.to_s
        if !table.column(key) && table.column("#{key}_id")
          values["#{key}_id"] = identify(value)
        else
          raise "fixture #{label}: #{table.name} has no column #{key}" unless table.column(key)
          values[key] = value
        end
      end
      table.columns.each do |c|
        next if values.key?(c.name)
        values[c.name] = c.timestamp? ? now : (c.default.nil? ? { integer: 0, boolean: false, float: 0.0, string: "" }.fetch(c.type) : c.default)
      end
      values
    end

    def load(app, tables)
      selected = tables.include?("all") ? rows(app) : rows(app).slice(*tables)
      missing = tables - ["all"] - selected.keys
      raise "no test/fixtures/#{missing.first}.yml" if missing.any?
      selected.map do |table, labelled|
        labelled.values.map do |r|
          names = r.attributes.keys
          "INSERT INTO #{table} (#{names.join(', ')}) VALUES (#{names.map { |n| sql(r.attributes[n]) }.join(', ')});\n"
        end.join
      end.join
    end

    def sql(value)
      case value
      when true then "1"
      when false then "0"
      when Numeric then value.to_s
      else "'#{value.to_s.gsub("'", "''")}'"
      end
    end
  end
end
