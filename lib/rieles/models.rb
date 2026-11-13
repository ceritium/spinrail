module Rieles
  # Turns `class Entry < ApplicationRecord` plus its table in db/schema.rb
  # into a plain class: typed accessors, a query relation, validations and
  # persistence, all spelled out because spinel has no define_method.
  class Model
    NOW = "datetime('now', 'localtime')".freeze

    attr_reader :name

    def initialize(file, schema)
      @file = file
      source = File.read(file)
      klass = Rieles.parse(source, file).statements.body.find { |n| n.is_a?(Prism::ClassNode) }
      raise CompileError, "#{file}: expected a class" unless klass
      @name = klass.constant_path.slice
      @parent = klass.superclass&.slice || "ApplicationRecord"
      table_name = Inflector.tableize(@name)
      @table = schema.table(table_name) or
        raise CompileError, "#{file}: no `create_table :#{table_name}` in db/schema.rb"
      @validations = []
      @body = []
      (klass.body&.body || []).each { |stmt| collect(stmt) }
    end

    def to_ruby
      [model_class, relation_class].join("\n")
    end

    private

    def collect(stmt)
      if stmt.is_a?(Prism::CallNode) && stmt.receiver.nil? && stmt.name == :validates
        validates(stmt)
      elsif stmt.is_a?(Prism::CallNode) && stmt.receiver.nil? && %i[has_many belongs_to has_one].include?(stmt.name)
        fail!(stmt, "#{stmt.name} is not supported yet")
      else
        @body << stmt.slice.gsub(/^ {#{stmt.location.start_column}}/, "")
      end
    end

    def validates(node)
      args, kw = Rieles.call_args(node)
      args.each do |arg|
        attr = Rieles.literal(arg).to_s
        column = @table.column(attr) or fail!(node, "unknown attribute #{attr}")
        fail!(node, "validates only supports string columns for now") if column.integer?
        kw.each do |kind, value_node|
          value = Rieles.literal(value_node)
          case kind
          when :presence
            @validations << [attr, "@#{attr}.strip.empty?", "can't be blank"] if value
          when :length
            if value[:maximum]
              @validations << [attr, "@#{attr}.length > #{value[:maximum]}", "is too long (maximum is #{value[:maximum]} characters)"]
            end
            if value[:minimum]
              @validations << [attr, "@#{attr}.length < #{value[:minimum]}", "is too short (minimum is #{value[:minimum]} characters)"]
            end
          else fail!(node, "unsupported validation #{kind}")
          end
        end
      end
    end

    def columns = @table.columns
    def writable = columns.reject { |c| c.name == "id" || c.timestamp? }
    def select_sql = "SELECT #{columns.map(&:name).join(', ')} FROM #{@table.name}"
    def find_sql = "#{select_sql} WHERE id = ?"
    def delete_sql = "DELETE FROM #{@table.name} WHERE id = ?"
    def relation = "#{@name}Relation"

    def binds(cols)
      cols.each_with_index.map do |c, i|
        "      db.bind_#{c.integer? ? 'int' : 'str'}(#{i + 1}, @#{c.name})"
      end.join("\n")
    end

    def insert_sql
      names = writable.map(&:name) + columns.select(&:timestamp?).map(&:name)
      values = writable.map { "?" } + columns.select(&:timestamp?).map { NOW }
      "INSERT INTO #{@table.name} (#{names.join(', ')}) VALUES (#{values.join(', ')})"
    end

    def update_sql
      sets = writable.map { |c| "#{c.name} = ?" }
      sets << "updated_at = #{NOW}" if @table.column("updated_at")
      "UPDATE #{@table.name} SET #{sets.join(', ')} WHERE id = ?"
    end

    def reload_timestamps
      columns.select(&:timestamp?).map { |c| "    @#{c.name} = saved.#{c.name}" }.join("\n")
    end

    # Interpolated lines sit at the heredoc's base indent so <<~ strips evenly.
    def model_class
      kwargs = columns.map { |c| "#{c.name}: #{c.default_literal}" }.join(", ")
      from_row = columns.each_with_index.map { |c, i| "#{c.name}: db.col_#{c.integer? ? 'int' : 'str'}(#{i})" }
      checks = @validations.map do |attr, cond, msg|
        full = "#{Inflector.humanize(attr)} #{msg}"
        "    @errors.add(#{attr.inspect}, #{msg.inspect}, #{full.inspect}) if #{cond}"
      end

      <<~RUBY
        class #{@name} < #{@parent}
          COLUMNS = #{columns.map(&:name).inspect}
          attr_accessor #{columns.map { |c| ":#{c.name}" }.join(', ')}
          attr_reader :errors

          def initialize(#{kwargs})
        #{columns.map { |c| "    @#{c.name} = #{c.name}" }.join("\n")}
            @errors = Rieles::Errors.new
          end

          def self.from_row(db)
            #{@name}.new(#{from_row.join(', ')})
          end

          def self.all = #{relation}.new
          def self.where(conditions) = all.where(conditions)
          def self.order(ordering) = all.order(ordering)
          def self.limit(n) = all.limit(n)
          def self.count = all.count

          def self.find(id)
            t0 = Rieles.clock
            db = Rieles.connect
            db.prepare(#{find_sql.inspect})
            db.bind_int(1, id.to_s.to_i)
            if db.step == 1
              record = #{@name}.from_row(db)
              db.finalize
              db.close
              Rieles.log.sql("#{@name} Load", #{find_sql.inspect}, t0)
              return record
            end
            db.finalize
            db.close
            Rieles.log.sql("#{@name} Load", #{find_sql.inspect}, t0)
            raise Rieles::RecordNotFound, "Couldn't find #{@name} with 'id'=" + id.to_s
          end

          def persisted? = @id > 0

          def valid?
            @errors.clear
        #{checks.join("\n")}
            @errors.empty?
          end

          def save
            return false unless valid?
            t0 = Rieles.clock
            db = Rieles.connect
            if persisted?
              db.prepare(#{update_sql.inspect})
        #{binds(writable)}
              db.bind_int(#{writable.size + 1}, @id)
              db.step
              db.finalize
              db.close
              Rieles.log.sql("#{@name} Update", #{update_sql.inspect}, t0)
            else
              db.prepare(#{insert_sql.inspect})
        #{binds(writable)}
              db.step
              db.finalize
              @id = db.last_rowid
              db.close
              Rieles.log.sql("#{@name} Create", #{insert_sql.inspect}, t0)
            end
            saved = #{@name}.find(@id)
        #{reload_timestamps}
            true
          end

          def destroy
            t0 = Rieles.clock
            db = Rieles.connect
            db.prepare(#{delete_sql.inspect})
            db.bind_int(1, @id)
            db.step
            db.finalize
            db.close
            Rieles.log.sql("#{@name} Destroy", #{delete_sql.inspect}, t0)
            true
          end

        #{@body.map { |s| s.gsub(/^(?=.)/, '  ') }.join("\n\n")}
        end
      RUBY
    end

    def relation_class
      <<~RUBY
        class #{relation}
          def initialize
            @wheres = []
            @binds = []
            @order = "id ASC"
            @limit = -1
            @loaded = false
            @records = []
          end

          def where(conditions)
            conditions.each do |column, value|
              raise ArgumentError, "unknown column " + column.to_s unless #{@name}::COLUMNS.include?(column.to_s)
              @wheres << column.to_s + " = ?"
              @binds << value.to_s
            end
            self
          end

          def order(ordering)
            clauses = []
            ordering.each do |column, direction|
              raise ArgumentError, "unknown column " + column.to_s unless #{@name}::COLUMNS.include?(column.to_s)
              dir = direction.to_s.upcase
              raise ArgumentError, "bad direction " + dir unless dir == "ASC" || dir == "DESC"
              clauses << column.to_s + " " + dir
            end
            @order = clauses.join(", ")
            self
          end

          def limit(n)
            @limit = n
            self
          end

          def to_a
            return @records if @loaded
            sql = #{select_sql.inspect}
            sql = sql + " WHERE " + @wheres.join(" AND ") unless @wheres.empty?
            sql = sql + " ORDER BY " + @order
            sql = sql + " LIMIT " + @limit.to_s if @limit >= 0
            t0 = Rieles.clock
            db = Rieles.connect
            db.prepare(sql)
            i = 0
            while i < @binds.length
              db.bind_str(i + 1, @binds[i])
              i += 1
            end
            while db.step == 1
              @records << #{@name}.from_row(db)
            end
            db.finalize
            db.close
            Rieles.log.sql("#{@name} Load", sql, t0)
            @loaded = true
            @records
          end

          def each
            to_a.each { |record| yield record }
          end

          def count = to_a.length
          def size = to_a.length
          def empty? = to_a.empty?
          def any? = !to_a.empty?
        end
      RUBY
    end

    def fail!(node, message)
      raise CompileError, "#{@file}:#{node.location.start_line}: #{message}"
    end
  end
end
