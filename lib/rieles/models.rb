module Rieles
  # Turns `class Entry < ApplicationRecord` plus its table in db/schema.rb
  # into a plain class: typed accessors, a query relation, validations,
  # callbacks, associations and persistence, all spelled out because spinel
  # has no define_method.
  class Model
    CALLBACKS = %i[before_validation after_validation before_save after_save before_create
                   after_create before_update after_update before_destroy after_destroy].freeze
    NUMBER = '/\A[+-]?\d+(\.\d+)?\z/'.freeze
    INTEGER = '/\A[+-]?\d+\z/'.freeze
    COMPARISONS = {
      greater_than: ["<=", "must be greater than"],
      greater_than_or_equal_to: ["<", "must be greater than or equal to"],
      less_than: [">=", "must be less than"],
      less_than_or_equal_to: [">", "must be less than or equal to"],
      equal_to: ["!=", "must be equal to"],
      other_than: ["==", "must be other than"]
    }.freeze

    Association = Struct.new(:kind, :name, :class_name, :foreign_key, :dependent, :optional)

    attr_reader :name

    def initialize(file, schema)
      @file = file
      @schema = schema
      source = File.read(file)
      klass = Rieles.parse(source, file).statements.body.find { |n| n.is_a?(Prism::ClassNode) }
      raise CompileError, "#{file}: expected a class" unless klass
      @name = klass.constant_path.slice
      @parent = klass.superclass&.slice || "ApplicationRecord"
      table_name = Inflector.tableize(@name)
      @table = schema.table(table_name) or
        raise CompileError, "#{file}: no `create_table :#{table_name}` in db/schema.rb"
      @validations = []
      @custom_validations = []
      @callbacks = Hash.new { |h, k| h[k] = [] }
      @associations = []
      @body = []
      (klass.body&.body || []).each { |stmt| collect(stmt) }
    end

    def to_ruby
      [model_class, relation_class].join("\n")
    end

    private

    def collect(stmt)
      call = stmt.is_a?(Prism::CallNode) && stmt.receiver.nil? ? stmt.name : nil
      if call == :validates
        validates(stmt)
      elsif call == :validate
        @custom_validations.concat(symbols(stmt))
      elsif CALLBACKS.include?(call)
        @callbacks[call].concat(symbols(stmt))
      elsif %i[has_many has_one belongs_to].include?(call)
        association(stmt)
      else
        @body << stmt.slice.gsub(/^ {#{stmt.location.start_column}}/, "")
      end
    end

    def symbols(node)
      args, kw = Rieles.call_args(node)
      fail!(node, "#{node.name} takes method names, not options") unless kw.empty?
      args.map { |a| Rieles.literal(a).to_s }
    end

    def association(node)
      args, kw = Rieles.call_args(node)
      name = Rieles.literal(args.first).to_s
      opts = kw.transform_values { |v| Rieles.literal(v) }
      unknown = opts.keys - %i[class_name foreign_key dependent optional]
      fail!(node, "unsupported #{node.name} option #{unknown.first}") if unknown.any?
      singular = node.name == :has_many ? Inflector.singularize(name) : name
      class_name = opts[:class_name] || Inflector.camelize(singular)
      fk = opts[:foreign_key]&.to_s || (node.name == :belongs_to ? "#{name}_id" : "#{Inflector.underscore(@name)}_id")
      fk_table = node.name == :belongs_to ? @table : @schema.table(Inflector.tableize(class_name))
      fail!(node, "no table #{Inflector.tableize(class_name)} for #{class_name}") unless fk_table
      fail!(node, "#{fk_table.name} has no #{fk} column") unless fk_table.column(fk)
      dependent = opts[:dependent]
      if dependent && !%i[destroy delete_all].include?(dependent)
        fail!(node, "dependent: only supports :destroy and :delete_all")
      end
      @associations << Association.new(node.name, name, class_name, fk, dependent, opts[:optional])
    end

    def validates(node)
      args, kw = Rieles.call_args(node)
      args.each do |arg|
        attr = Rieles.literal(arg).to_s
        assoc = @associations.find { |a| a.kind == :belongs_to && a.name == attr }
        if assoc
          kw.each_key { |k| fail!(node, "only presence is supported on #{attr}") unless k == :presence }
          @validations << [attr, "!#{assoc.class_name}.where(id: @#{assoc.foreign_key}).exists?", "must exist"]
          next
        end
        column = @table.column(attr) or fail!(node, "unknown attribute #{attr}")
        kw.each { |kind, value_node| validation(node, column, kind, value_node) }
      end
    end

    def validation(node, column, kind, value_node)
      attr = column.name
      ivar = "@#{attr}"
      value = value_node.is_a?(Prism::HashNode) ? value_node.elements.to_h { |a| [Rieles.literal(a.key), a.value] } : {}
      message = value[:message] && Rieles.literal(value[:message])
      add = ->(cond, msg) { @validations << [attr, cond, message || msg] }
      case kind
      when :presence
        fail!(node, "presence only applies to string columns (#{attr} is #{column.type})") unless column.string?
        add.("#{ivar}.strip.empty?", "can't be blank") if Rieles.literal(value_node)
      when :length
        fail!(node, "length only applies to string columns") unless column.string?
        { maximum: [">", "is too long (maximum is %d characters)"], minimum: ["<", "is too short (minimum is %d characters)"],
          is: ["!=", "is the wrong length (should be %d characters)"] }.each do |key, (op, msg)|
          next unless value[key]
          n = Rieles.literal(value[key])
          add.("#{ivar}.length #{op} #{n}", format(msg, n))
        end
      when :numericality
        numericality(column, value, add)
      when :format
        fail!(node, "format only applies to string columns") unless column.string?
        add.("!#{ivar}.match?(#{value[:with].slice})", "is invalid") if value[:with]
        add.("#{ivar}.match?(#{value[:without].slice})", "is invalid") if value[:without]
      when :inclusion
        add.("!(#{value.fetch(:in).slice}).include?(#{ivar})", "is not included in the list")
      when :exclusion
        add.("(#{value.fetch(:in).slice}).include?(#{ivar})", "is reserved")
      when :uniqueness
        add.("#{@name}.where(#{attr}: #{ivar}).where_not(id: @id).exists?", "has already been taken")
      else fail!(node, "unsupported validation #{kind}")
      end
    end

    def numericality(column, value, add)
      ivar = "@#{column.name}"
      number = ivar
      guard = ""
      if column.string?
        pattern = value[:only_integer] ? INTEGER : NUMBER
        add.("!#{ivar}.match?(#{pattern})", value[:only_integer] ? "must be an integer" : "is not a number")
        number = "#{ivar}.to_f"
        guard = "#{ivar}.match?(#{pattern}) && "
      end
      COMPARISONS.each do |key, (op, msg)|
        next unless value[key]
        limit = value[key].slice
        add.("#{guard}#{number} #{op} #{limit}", "#{msg} #{limit}")
      end
    end

    def columns = @table.columns
    def writable = columns.reject { |c| c.name == "id" || c.timestamp? }
    def assignable = columns.reject { |c| c.name == "id" }
    def select_sql = "SELECT #{columns.map(&:name).join(', ')} FROM #{@table.name}"
    def relation = "#{@name}Relation"

    def insert_sql
      names = writable.map(&:name) + columns.select(&:timestamp?).map(&:name)
      "INSERT INTO #{@table.name} (#{names.join(', ')}) VALUES (#{(['?'] * names.size).join(', ')})"
    end

    def update_sql
      sets = writable.map { |c| "#{c.name} = ?" }
      sets << "updated_at = ?" if @table.column("updated_at")
      "UPDATE #{@table.name} SET #{sets.join(', ')} WHERE id = ?"
    end

    def delete_sql = "DELETE FROM #{@table.name} WHERE id = ?"

    def indent(lines, n) = Array(lines).flat_map { |l| l.split("\n") }.map { |l| l.empty? ? l : (" " * n) + l }.join("\n")

    def run_callbacks(kind) = @callbacks[kind].join("\n")

    def write_statement(sql, label, cols, extra)
      binds = cols.each_with_index.map { |c, i| c.bind(i + 1, "@#{c.name}") }
      binds += extra.each_with_index.map { |e, i| e.sub("%d", (cols.size + i + 1).to_s) }
      [
        "t0 = Rieles.clock",
        "db = Rieles.prepare(#{sql.inspect}, true)",
        *binds,
        "Rieles.write(db, #{"#{@name} #{label}".inspect}, #{sql.inspect}, t0)"
      ].join("\n")
    end

    def save_method
      timestamps = columns.select(&:timestamp?).map(&:name)
      stamp = timestamps.empty? ? "" : "now = Rieles.now\n"
      insert_stamps = timestamps.map { |t| "db.bind_str(%d, now)" }
      create = [stamp + run_callbacks(:before_create), write_statement(insert_sql, "Create", writable, insert_stamps),
                "@id = db.last_rowid", *timestamps.map { |t| "@#{t} = now" }, run_callbacks(:after_create)]
      update_stamps = @table.column("updated_at") ? ["db.bind_str(%d, now)"] : []
      update = [stamp + run_callbacks(:before_update),
                write_statement(update_sql, "Update", writable, update_stamps + ["db.bind_int(%d, @id)"]),
                *(@table.column("updated_at") ? ["@updated_at = now"] : []), run_callbacks(:after_update)]
      <<~RUBY
        def save
          return false unless valid?
        #{indent(run_callbacks(:before_save), 2)}
          if persisted?
        #{indent(update, 4)}
          else
        #{indent(create, 4)}
          end
        #{indent(run_callbacks(:after_save), 2)}
          true
        end
      RUBY
    end

    def destroy_method
      dependents = @associations.filter_map do |a|
        next unless a.dependent
        if a.kind == :has_one
          "dependent = #{a.name}\ndependent.destroy if dependent"
        elsif a.dependent == :destroy
          "#{a.name}.each { |record| record.destroy }"
        else
          "#{a.name}.delete_all"
        end
      end
      <<~RUBY
        def destroy
        #{indent(run_callbacks(:before_destroy), 2)}
        #{indent(dependents, 2)}
        #{indent(write_statement(delete_sql, "Destroy", [], ["db.bind_int(%d, @id)"]), 2)}
        #{indent(run_callbacks(:after_destroy), 2)}
          true
        end
      RUBY
    end

    def association_methods
      @associations.map do |a|
        case a.kind
        when :belongs_to
          "def #{a.name} = #{a.class_name}.find_by(id: @#{a.foreign_key})\n\n" \
            "def #{a.name}=(record)\n  @#{a.foreign_key} = record.id\nend"
        when :has_many then "def #{a.name} = #{a.class_name}.where(#{a.foreign_key}: @id)"
        when :has_one then "def #{a.name} = #{a.class_name}.find_by(#{a.foreign_key}: @id)"
        end
      end
    end

    # belongs_to is required unless optional: true, as in Rails 5+.
    def required_associations
      @associations.select { |a| a.kind == :belongs_to && !a.optional && @validations.none? { |v| v[0] == a.name } }
                   .map { |a| [a.name, "!#{a.class_name}.where(id: @#{a.foreign_key}).exists?", "must exist"] }
    end

    def user_methods
      return "" if @body.empty?
      source = @body.join("\n\n")
      Lowering.lower(source, @file, Build::Context.new(nil, "", view: false))
    end

    def model_class
      kwargs = columns.map { |c| "#{c.name}: #{c.default_literal}" }.join(", ")
      new_args = assignable.map { |c| "#{c.name}: #{c.name}" }.join(", ")
      create_kwargs = assignable.map { |c| "#{c.name}: #{c.default_literal}" }.join(", ")
      update_kwargs = assignable.map { |c| "#{c.name}: @#{c.name}" }.join(", ")
      assign = assignable.map { |c| "@#{c.name} = #{c.name}" }
      from_row = columns.each_with_index.map { |c, i| "#{c.name}: #{c.read(i)}" }
      checks = (@validations + required_associations).map do |attr, cond, msg|
        "@errors.add(:#{attr}, #{msg.inspect}, #{"#{Inflector.humanize(attr)} #{msg}".inspect}) if #{cond}"
      end
      plucks = columns.map { |c| "def self.pluck_#{c.name} = all.pluck_#{c.name}" }
      predicates = columns.select(&:boolean?).map { |c| "def #{c.name}? = @#{c.name}" }
      <<~RUBY
        class #{@name} < #{@parent}
          COLUMNS = #{columns.map(&:name).inspect}
          attr_accessor #{columns.map { |c| ":#{c.name}" }.join(', ')}
          attr_reader :errors

          def initialize(#{kwargs})
        #{indent(columns.map { |c| "@#{c.name} = #{c.name}" }, 4)}
            @errors = Rieles::Errors.new
          end

          def self.from_row(db)
            #{@name}.new(#{from_row.join(', ')})
          end

          def self.all = #{relation}.new
          def self.where(conditions) = all.where(conditions)
          def self.where_not(conditions) = all.where_not(conditions)
          def self.order(ordering) = all.order(ordering)
          def self.order_sql(clause) = all.order_sql(clause)
          def self.limit(n) = all.limit(n)
          def self.offset(n) = all.offset(n)
          def self.first = all.first
          def self.last = all.last
          def self.count = all.count
          def self.exists? = all.exists?
          def self.delete_all = all.delete_all
          def self.find_by(conditions) = all.where(conditions).first
        #{indent(plucks, 2)}

          def self.find(id)
            record = #{@name}.where(id: id.to_s.to_i).first
            raise Rieles::RecordNotFound, "Couldn't find #{@name} with 'id'=" + id.to_s unless record
            record
          end

          def self.create(#{create_kwargs})
            record = #{@name}.new(#{new_args})
            record.save
            record
          end

          def self.create!(#{create_kwargs})
            record = #{@name}.new(#{new_args})
            record.save!
            record
          end

          def self.transaction
            Rieles.transaction { yield }
          end

          def persisted? = @id > 0
          def new_record? = @id == 0
        #{indent(predicates, 2)}

          def valid?
            @errors.clear
        #{indent(run_callbacks(:before_validation), 4)}
        #{indent(checks, 4)}
        #{indent(@custom_validations, 4)}
        #{indent(run_callbacks(:after_validation), 4)}
            @errors.empty?
          end

          def invalid? = !valid?

        #{indent(save_method, 2)}

          def save!
            raise Rieles::RecordInvalid, "Validation failed: " + @errors.full_messages.join(", ") unless save
            true
          end

          def update(#{update_kwargs})
        #{indent(assign, 4)}
            save
          end

          def update!(#{update_kwargs})
        #{indent(assign, 4)}
            save!
          end

          def reload
            fresh = #{@name}.find(@id)
        #{indent(assignable.map { |c| "@#{c.name} = fresh.#{c.name}" }, 4)}
            self
          end

        #{indent(destroy_method, 2)}

        #{indent(association_methods.join("\n\n"), 2)}

        #{indent(user_methods, 2)}
        end
      RUBY
    end

    def relation_class
      booleans = columns.select(&:boolean?).map(&:name)
      bool_value = if booleans.empty?
                     "value"
                   else
                     "return value unless #{booleans.map { |b| "name == #{b.inspect}" }.join(' || ')}\n" \
                       "value == \"true\" ? \"1\" : (value == \"false\" ? \"0\" : value)"
                   end
      plucks = columns.each_with_index.map do |c, _|
        <<~RUBY
          def pluck_#{c.name}
            t0 = Rieles.clock
            statement = sql(#{c.name.inspect})
            db = Rieles.prepare(statement, false)
            bind_all(db)
            values = []
            while db.step == 1
              values << #{c.read(0)}
            end
            db.finalize
            Rieles.log.sql(#{"#{@name} Pluck".inspect}, statement, t0)
            values
          end
        RUBY
      end
      <<~RUBY
        class #{relation}
          attr_reader :wheres, :binds, :ordering, :raw_order, :limit_value, :offset_value

          def initialize
            @wheres = []
            @binds = []
            @ordering = []
            @raw_order = ""
            @limit_value = -1
            @offset_value = -1
            @loaded = false
            @records = []
          end

          def restore(other)
            @wheres = other.wheres.dup
            @binds = other.binds.dup
            @ordering = other.ordering.dup
            @raw_order = other.raw_order
            @limit_value = other.limit_value
            @offset_value = other.offset_value
            self
          end

          def spawn = #{relation}.new.restore(self)

          def where(conditions)
            relation = spawn
            conditions.each { |column, value| relation.add_where(column.to_s, value.to_s, "=") }
            relation
          end

          def where_not(conditions)
            relation = spawn
            conditions.each { |column, value| relation.add_where(column.to_s, value.to_s, "!=") }
            relation
          end

          def add_where(name, value, op)
            raise ArgumentError, "unknown column " + name unless #{@name}::COLUMNS.include?(name)
            @wheres << name + " " + op + " ?"
            @binds << sql_value(name, value)
          end

          def sql_value(name, value)
        #{indent(bool_value, 4)}
          end

          def order(ordering)
            relation = spawn
            ordering.each do |column, direction|
              name = column.to_s
              raise ArgumentError, "unknown column " + name unless #{@name}::COLUMNS.include?(name)
              dir = direction.to_s.upcase
              raise ArgumentError, "bad direction " + dir unless dir == "ASC" || dir == "DESC"
              relation.add_order(name + " " + dir)
            end
            relation
          end

          def add_order(clause)
            @ordering << clause
          end

          def order_sql(clause)
            relation = spawn
            relation.set_raw_order(clause)
            relation
          end

          def set_raw_order(clause)
            @raw_order = clause
          end

          def limit(n)
            relation = spawn
            relation.set_limit(n)
            relation
          end

          def set_limit(n)
            @limit_value = n
          end

          def offset(n)
            relation = spawn
            relation.set_offset(n)
            relation
          end

          def set_offset(n)
            @offset_value = n
          end

          def order_clause
            return @raw_order if @raw_order.length > 0
            return "id ASC" if @ordering.empty?
            @ordering.join(", ")
          end

          def where_clause
            @wheres.empty? ? "" : " WHERE " + @wheres.join(" AND ")
          end

          def sql(select)
            statement = "SELECT " + select + " FROM #{@table.name}" + where_clause + " ORDER BY " + order_clause
            if @limit_value >= 0 || @offset_value >= 0
              statement = statement + " LIMIT " + @limit_value.to_s
              statement = statement + " OFFSET " + @offset_value.to_s if @offset_value >= 0
            end
            statement
          end

          def bind_all(db)
            i = 0
            while i < @binds.length
              db.bind_str(i + 1, @binds[i])
              i += 1
            end
          end

          def to_a
            return @records if @loaded
            t0 = Rieles.clock
            statement = sql(#{columns.map(&:name).join(', ').inspect})
            db = Rieles.prepare(statement, false)
            bind_all(db)
            while db.step == 1
              @records << #{@name}.from_row(db)
            end
            db.finalize
            Rieles.log.sql(#{"#{@name} Load".inspect}, statement, t0)
            @loaded = true
            @records
          end

          def first
            return to_a.first if @loaded
            limit(1).to_a.first
          end

          def last
            raise ArgumentError, "last needs an order by column, not SQL" if @raw_order.length > 0
            relation = spawn
            relation.reverse_order
            relation.set_limit(1)
            relation.to_a.first
          end

          def reverse_order
            @ordering = ["id ASC"] if @ordering.empty?
            @ordering = @ordering.map { |c| c.end_with?(" ASC") ? c.sub(" ASC", " DESC") : c.sub(" DESC", " ASC") }
          end

          def count
            return @records.length if @loaded
            return to_a.length if @limit_value >= 0 || @offset_value >= 0
            t0 = Rieles.clock
            statement = "SELECT COUNT(*) FROM #{@table.name}" + where_clause
            db = Rieles.prepare(statement, false)
            bind_all(db)
            n = db.step == 1 ? db.col_int(0) : 0
            db.finalize
            Rieles.log.sql(#{"#{@name} Count".inspect}, statement, t0)
            n
          end

          def exists?
            return !@records.empty? if @loaded
            limit(1).to_a.length > 0
          end

          def delete_all
            t0 = Rieles.clock
            statement = "DELETE FROM #{@table.name}" + where_clause
            db = Rieles.prepare(statement, false)
            bind_all(db)
            Rieles.write(db, #{"#{@name} Delete All".inspect}, statement, t0)
          end

        #{indent(plucks, 2)}

          def each
            to_a.each { |record| yield record }
          end

          def each_with_index
            to_a.each_with_index { |record, i| yield record, i }
          end

          def size = count
          def length = to_a.length
          def empty? = !exists?
          def any? = exists?
          def none? = !exists?
        end
      RUBY
    end

    def fail!(node, message)
      raise CompileError, "#{@file}:#{node.location.start_line}: #{message}"
    end
  end
end
