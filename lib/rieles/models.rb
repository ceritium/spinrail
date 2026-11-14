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
      greater_than: ["<=", "must be greater than %{count}"],
      greater_than_or_equal_to: ["<", "must be greater than or equal to %{count}"],
      less_than: [">=", "must be less than %{count}"],
      less_than_or_equal_to: [">", "must be less than or equal to %{count}"],
      equal_to: ["!=", "must be equal to %{count}"],
      other_than: ["==", "must be other than %{count}"]
    }.freeze

    # Default English messages, keyed like Rails' errors.messages.*, so
    # config/locales can translate them.

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
      @scopes = []
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
        @custom_validations.concat(guarded_calls(stmt))
      elsif CALLBACKS.include?(call)
        @callbacks[call].concat(guarded_calls(stmt))
      elsif %i[has_many has_one belongs_to].include?(call)
        association(stmt)
      elsif call == :scope
        scope(stmt)
      elsif call == :has_secure_password
        fail!(stmt, "has_secure_password needs a password_digest column") unless @table.column("password_digest")
        @secure_password = true
      else
        @body << stmt.slice.gsub(/^ {#{stmt.location.start_column}}/, "")
      end
    end

    # before_save :x, if: :y -> "x if y"
    def guarded_calls(node)
      args, kw = Rieles.call_args(node)
      guard = guard(node, kw)
      args.map { |a| guard ? "#{Rieles.literal(a)} if #{guard}" : Rieles.literal(a).to_s }
    end

    # if:/unless: take method names; on: :create or :update.
    def guard(node, kw)
      unknown = kw.keys - %i[if unless on]
      fail!(node, "unsupported option #{unknown.first}") if unknown.any?
      parts = []
      { if: "", unless: "!" }.each do |key, neg|
        next unless kw[key]
        fail!(node, "#{key}: takes a method name") unless kw[key].is_a?(Prism::SymbolNode)
        parts << "#{neg}#{kw[key].unescaped}"
      end
      if kw[:on]
        on = Rieles.literal(kw[:on])
        fail!(node, "on: takes :create or :update") unless %i[create update].include?(on)
        parts << (on == :create ? "!persisted?" : "persisted?")
      end
      parts.empty? ? nil : parts.join(" && ")
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

    # scope :published, -> { where(published: true) } becomes a relation
    # method (so scopes chain) and a class method.
    def scope(node)
      args, = Rieles.call_args(node)
      name = Rieles.literal(args[0]).to_s
      lambda = args[1]
      fail!(node, "scope :name, -> { ... }") unless lambda.is_a?(Prism::LambdaNode)
      params = lambda.parameters&.parameters&.requireds&.map(&:name) || []
      body = lambda.body ? lambda.body.slice : "self"
      @scopes << [name, params, body]
    end

    def validates(node)
      args, kw = Rieles.call_args(node)
      @guard = guard(node, kw.slice(:if, :unless, :on))
      kw = kw.reject { |k, _| %i[if unless on].include?(k) }
      args.each do |arg|
        attr = Rieles.literal(arg).to_s
        assoc = @associations.find { |a| a.kind == :belongs_to && a.name == attr }
        if assoc
          kw.each_key { |k| fail!(node, "only presence is supported on #{attr}") unless k == :presence }
          @validations << [attr, guarded("!#{assoc.class_name}.where(id: @#{assoc.foreign_key}).exists?"), ["required", "must exist", ""]]
          next
        end
        column = @table.column(attr) or fail!(node, "unknown attribute #{attr}")
        kw.each { |kind, value_node| validation(node, column, kind, value_node) }
      end
      @guard = nil
    end

    def guarded(cond) = @guard ? "(#{@guard}) && (#{cond})" : cond

    def validation(node, column, kind, value_node)
      attr = column.name
      ivar = "@#{attr}"
      value = value_node.is_a?(Prism::HashNode) ? value_node.elements.to_h { |a| [Rieles.literal(a.key), a.value] } : {}
      message = value[:message] && Rieles.literal(value[:message])
      add = ->(cond, key, text, count = "") { @validations << [attr, guarded(cond), message ? [nil, message, ""] : [key, text, count.to_s]] }
      case kind
      when :presence
        if column.string?
          add.("#{column.null ? "#{ivar}.nil? || " : ''}#{ivar}.strip.empty?", "blank", "can't be blank") if Rieles.literal(value_node)
        elsif column.null
          add.("#{ivar}.nil?", "blank", "can't be blank") if Rieles.literal(value_node)
        else
          fail!(node, "presence on a NOT NULL #{column.type} column is always true; declare it null: true")
        end
      when :length
        fail!(node, "length only applies to string columns") unless column.string?
        ivar = "#{ivar}.to_s" if column.null
        { maximum: [">", "too_long", "is too long (maximum is %{count} characters)"],
          minimum: ["<", "too_short", "is too short (minimum is %{count} characters)"],
          is: ["!=", "wrong_length", "is the wrong length (should be %{count} characters)"] }.each do |key, (op, i18n, msg)|
          next unless value[key]
          n = Rieles.literal(value[key])
          add.("#{ivar}.length #{op} #{n}", i18n, msg, n)
        end
      when :numericality
        numericality(column, value, add)
      when :format
        fail!(node, "format only applies to string columns") unless column.string?
        ivar = "#{ivar}.to_s" if column.null
        add.("!#{ivar}.match?(#{value[:with].slice})", "invalid", "is invalid") if value[:with]
        add.("#{ivar}.match?(#{value[:without].slice})", "invalid", "is invalid") if value[:without]
      when :inclusion
        add.("!(#{value.fetch(:in).slice}).include?(#{ivar})", "inclusion", "is not included in the list")
      when :exclusion
        add.("(#{value.fetch(:in).slice}).include?(#{ivar})", "exclusion", "is reserved")
      when :uniqueness
        add.("#{@name}.where(#{attr}: #{ivar}).where_not(id: @id).exists?", "taken", "has already been taken")
      else fail!(node, "unsupported validation #{kind}")
      end
    end

    def numericality(column, value, add)
      ivar = "@#{column.name}"
      number = ivar
      guard = column.null && !column.string? ? "!#{ivar}.nil? && " : ""
      ivar = "#{ivar}.to_s" if column.null && column.string?
      if column.string?
        pattern = value[:only_integer] ? INTEGER : NUMBER
        add.("!#{ivar}.match?(#{pattern})", *(value[:only_integer] ? ["not_an_integer", "must be an integer"] : ["not_a_number", "is not a number"]))
        number = "#{ivar}.to_f"
        guard = "#{ivar}.match?(#{pattern}) && "
      end
      COMPARISONS.each do |key, (op, msg)|
        next unless value[key]
        limit = value[key].slice
        add.("#{guard}#{number} #{op} #{limit}", key.to_s, msg, limit)
      end
    end

    def columns = @table.columns
    def writable = columns.reject { |c| c.name == "id" || c.timestamp? }
    def assignable = columns.reject { |c| c.name == "id" }
    def select_sql = "SELECT #{select_list} FROM #{@table.name}"

    # Column names, then "x IS NULL" for each nullable one.
    # Qualified with the table so joins can't make them ambiguous.
    def select_list
      q = ->(name) { "#{@table.name}.#{name}" }
      (columns.map { |c| q.(c.name) } + columns.select(&:null).map { |c| "#{q.(c.name)} IS NULL" }).join(", ")
    end

    def null_flag(column)
      nullable = columns.select(&:null)
      i = nullable.index(column)
      i && columns.size + i
    end
    def relation = "#{@name}Relation"

    def param_assignments
      writable.map do |c|
        read = "params.get(#{c.name.inspect})"
        value = case c.type
                when :integer then c.null ? "(#{read}.empty? ? nil : #{read}.to_i)" : "#{read}.to_i"
                when :float then c.null ? "(#{read}.empty? ? nil : #{read}.to_f)" : "#{read}.to_f"
                when :boolean then "(#{read} == \"1\" || #{read} == \"true\" || #{read} == \"on\")"
                else read
                end
        "@#{c.name} = #{value} if params.has?(#{c.name.inspect})"
      end + virtual.map { |v| "self.#{v} = params.get(#{v.inspect}) if params.has?(#{v.inspect})" }
    end

    # has_secure_password: password and password_confirmation aren't columns.
    def virtual = @secure_password ? %w[password password_confirmation] : []

    def json_fields = columns.reject { |c| c.name == "password_digest" }.map { |c| "#{%("#{c.name}":).inspect} + @#{c.name}.to_json" }.join(%( + "," + ))

    def insert_sql
      cols = writable + columns.select(&:timestamp?)
      "INSERT INTO #{@table.name} (#{cols.map(&:name).join(', ')}) VALUES (#{cols.map(&:placeholder).join(', ')})"
    end

    def update_sql
      sets = writable.map { |c| "#{c.name} = #{c.placeholder}" }
      sets << "updated_at = ?" if @table.column("updated_at")
      "UPDATE #{@table.name} SET #{sets.join(', ')} WHERE id = ?"
    end

    def delete_sql = "DELETE FROM #{@table.name} WHERE id = ?"

    def indent(lines, n) = Array(lines).flat_map { |l| l.split("\n") }.map { |l| l.empty? ? l : (" " * n) + l }.join("\n")

    # before_* callbacks may `throw :abort` to cancel the operation.
    def run_callbacks(kind)
      calls = @callbacks[kind]
      return calls.join("\n") unless kind.to_s.start_with?("before_") && kind != :before_validation && calls.any?
      "halted = catch(:abort) do\n#{calls.map { |c| "  #{c}" }.join("\n")}\n  false\nend\nreturn false if halted.nil?"
    end

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

    # Readers use what includes(...) preloaded, else query.
    def association_methods
      @associations.map do |a|
        case a.kind
        when :belongs_to
          "def #{a.name} = @preloaded_#{a.name} ? @#{a.name}_record : #{a.class_name}.find_by(id: @#{a.foreign_key})\n\n" \
            "def #{a.name}=(record)\n  @#{a.foreign_key} = record.id\nend\n\n" \
            "def preload_set_#{a.name}(record)\n  @#{a.name}_record = record\n  @preloaded_#{a.name} = true\nend"
        when :has_many
          "def #{a.name}\n  relation = #{a.class_name}.where(#{a.foreign_key}: @id)\n" \
            "  @preloaded_#{a.name} ? relation.with_records(@#{a.name}_records) : relation\nend\n\n" \
            "def preload_set_#{a.name}(records)\n  @#{a.name}_records = records\n  @preloaded_#{a.name} = true\nend"
        when :has_one
          "def #{a.name} = @preloaded_#{a.name} ? @#{a.name}_record : #{a.class_name}.find_by(#{a.foreign_key}: @id)\n\n" \
            "def preload_set_#{a.name}(record)\n  @#{a.name}_record = record\n  @preloaded_#{a.name} = true\nend"
        end
      end
    end

    # name, or "left:name" for left_joins.
    def join_sql_method
      branches = @associations.flat_map do |a|
        target = Inflector.tableize(a.class_name)
        on = a.kind == :belongs_to ? "#{target}.id = #{@table.name}.#{a.foreign_key}" : "#{target}.#{a.foreign_key} = #{@table.name}.id"
        ["return #{"INNER JOIN #{target} ON #{on}".inspect} if name == #{a.name.inspect}",
         "return #{"LEFT OUTER JOIN #{target} ON #{on}".inspect} if name == #{"left:#{a.name}".inspect}"]
      end
      "def self.join_sql(name)\n#{indent(branches, 2)}\n  raise ArgumentError, #{"#{@name} has no association ".inspect} + name\nend"
    end

    # One query per included association for the whole batch.
    def preload_method
      branches = @associations.map do |a|
        case a.kind
        when :belongs_to
          "if name == #{a.name.inspect}\n" \
            "  found = #{a.class_name}.all.where_in(\"id\", records.map { |r| r.#{a.foreign_key}.to_s }.uniq).to_a\n" \
            "  records.each { |r| r.preload_set_#{a.name}(found.find { |f| f.id == r.#{a.foreign_key} }) }"
        when :has_many
          "if name == #{a.name.inspect}\n" \
            "  found = #{a.class_name}.all.where_in(#{a.foreign_key.inspect}, records.map { |r| r.id.to_s }).to_a\n" \
            "  records.each { |r| r.preload_set_#{a.name}(found.select { |f| f.#{a.foreign_key} == r.id }) }"
        when :has_one
          "if name == #{a.name.inspect}\n" \
            "  found = #{a.class_name}.all.where_in(#{a.foreign_key.inspect}, records.map { |r| r.id.to_s }).to_a\n" \
            "  records.each { |r| r.preload_set_#{a.name}(found.find { |f| f.#{a.foreign_key} == r.id }) }"
        end
      end
      raise_line = "raise ArgumentError, #{"#{@name} has no association ".inspect} + name"
      body = branches.empty? ? raise_line : branches.join("\nels") + "\nelse\n  #{raise_line}\nend"
      "def self.preload_association(records, name)\n#{indent(body, 2)}\nend"
    end

    # belongs_to is required unless optional: true, as in Rails 5+.
    def required_associations
      @associations.select { |a| a.kind == :belongs_to && !a.optional && @validations.none? { |v| v[0] == a.name } }
                   .map { |a| [a.name, "!#{a.class_name}.where(id: @#{a.foreign_key}).exists?", ["required", "must exist", ""]] }
    end

    def user_methods
      return "" if @body.empty?
      source = @body.join("\n\n")
      Lowering.lower(source, @file, Build::Context.new(nil, "", view: false))
    end

    def model_class
      kwargs = (columns.map { |c| "#{c.name}: #{c.default_literal}" } + virtual.map { |v| "#{v}: \"\"" }).join(", ")
      update_kwargs = (assignable.map { |c| "#{c.name}: @#{c.name}" } + virtual.map { |v| "#{v}: \"\"" }).join(", ")
      assign = assignable.map { |c| "@#{c.name} = #{c.name}" } + secure_assign
      from_row = columns.each_with_index.map { |c, i| "#{c.name}: #{c.read(i, null_flag(c))}" }
      checks = (@validations + required_associations + secure_validations).map do |attr, cond, (key, text, count)|
        message = key ? "Rieles.message(#{key.inspect}, #{text.inspect}, #{count.inspect})" : text.inspect
        "@errors.add(:#{attr}, #{message}) if #{cond}"
      end
      plucks = columns.map { |c| "def self.pluck_#{c.name} = all.pluck_#{c.name}" }
      predicates = columns.select(&:boolean?).map { |c| "def #{c.name}? = @#{c.name}" }
      <<~RUBY
        class #{@name} < #{@parent}
          COLUMNS = #{columns.map(&:name).inspect}
          attr_accessor #{columns.map { |c| ":#{c.name}" }.join(', ')}
          attr_reader :errors
        #{@secure_password ? "  attr_reader :password\n  attr_accessor :password_confirmation\n\n  def password=(plain)\n    @password = plain\n    @password_digest = Tep::Password.hash(plain) unless plain.empty?\n  end\n\n  # true or false (Rails returns the record or false).\n  def authenticate(plain) = !@password_digest.empty? && Tep::Password.verify(plain, @password_digest)\n" : ""}
          def initialize(#{kwargs})
        #{indent(columns.map { |c| "@#{c.name} = #{c.name}" }, 4)}
        #{indent(@secure_password ? ["@password = \"\"", *secure_assign] : [], 4)}
            @errors = Rieles::Errors.new(#{Inflector.underscore(@name).inspect})
        #{indent(@associations.map { |a| "@preloaded_#{a.name} = false" }, 4)}
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
          def self.update_all(changes) = all.update_all(changes)
          def self.with_includes(names) = all.with_includes(names)
          def self.with_joins(names) = all.with_joins(names)
          def self.distinct = all.distinct
          def self.where_qualified(column, value) = all.where_qualified(column, value)
          def self.group_count(name) = all.group_count(name)
        #{indent(join_sql_method, 2)}
        #{indent(preload_method, 2)}
        #{indent(@scopes.map { |n, ps, _| sig = ps.empty? ? '' : "(#{ps.join(', ')})"; "def self.#{n}#{sig} = all.#{n}#{sig}" }, 2)}
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

          def to_param = @id.to_s
          def dom_id = @id > 0 ? #{"#{Inflector.underscore(@name)}_".inspect} + @id.to_s : #{"new_#{Inflector.underscore(@name)}".inspect}
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

          def self.from_params(params)
            record = #{@name}.new
            record.assign_params(params)
            record
          end

          def self.create_from(params)
            record = #{@name}.from_params(params)
            record.save
            record
          end

          def self.create_from!(params)
            record = #{@name}.from_params(params)
            record.save!
            record
          end

          def assign_params(params)
        #{indent(param_assignments, 4)}
            self
          end

          def update_from(params)
            assign_params(params)
            save
          end

          def update_from!(params)
            assign_params(params)
            save!
          end

          def to_json
            "{" + #{json_fields} + "}"
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

    def scope_methods
      return [] if @scopes.empty?
      source = @scopes.map do |name, params, body|
        "def #{name}#{params.empty? ? '' : "(#{params.join(', ')})"}\n#{body.gsub(/^\s*/, '  ')}\nend"
      end.join("\n\n")
      [Lowering.lower(source, @file, Build::Context.new(nil, "", view: false))]
    end

    def create_kwargs = (assignable.map { |c| "#{c.name}: #{c.default_literal}" } + virtual.map { |v| "#{v}: \"\"" }).join(", ")
    def new_args = (assignable.map(&:name) + virtual).map { |n| "#{n}: #{n}" }.join(", ")

    def secure_assign
      return [] unless @secure_password
      ["self.password = password unless password.empty?", "@password_confirmation = password_confirmation"]
    end

    def secure_validations
      return [] unless @secure_password
      [["password", "@password_digest.empty?", ["blank", "can't be blank", ""]],
       ["password_confirmation", "!@password_confirmation.empty? && @password_confirmation != @password",
        ["confirmation", "doesn't match Password", ""]]]
    end

    def scope_assignments
      assignable.map do |c|
        value = case c.type
                when :integer then "value.to_i"
                when :float then "value.to_f"
                when :boolean then 'value == "1"'
                else "value"
                end
        "record.#{c.name} = #{value} if name == #{c.name.inspect}"
      end
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
            return @records.map { |r| r.#{c.name} } if @loaded
            t0 = Rieles.clock
            statement = sql(#{(c.null ? "#{@table.name}.#{c.name}, #{@table.name}.#{c.name} IS NULL" : "#{@table.name}.#{c.name}").inspect})
            db = Rieles.prepare(statement, false)
            bind_all(db)
            values = []
            while db.step == 1
              values << #{c.read(0, c.null ? 1 : nil)}
            end
            db.finalize
            Rieles.log.sql_binds(#{"#{@name} Pluck".inspect}, statement, t0, @binds)
            values
          end
        RUBY
      end
      <<~RUBY
        class #{relation}
          attr_reader :wheres, :binds, :ordering, :raw_order, :limit_value, :offset_value, :scope_columns, :scope_values,
                      :include_names, :join_names

          def initialize
            @wheres = []
            @binds = []
            @scope_columns = []
            @scope_values = []
            @include_names = []
            @join_names = []
            @distinct = false
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
            @scope_columns = other.scope_columns.dup
            @scope_values = other.scope_values.dup
            @include_names = other.include_names.dup
            @join_names = other.join_names.dup
            @distinct = other.distinct?
            @ordering = other.ordering.dup
            @raw_order = other.raw_order
            @limit_value = other.limit_value
            @offset_value = other.offset_value
            self
          end

          def spawn = #{relation}.new.restore(self)
          def all = spawn
          def distinct? = @distinct

          def where(conditions)
            relation = spawn
            conditions.each do |column, value|
              if value.nil?
                relation.add_where_null(column.to_s, "IS NULL")
              else
                relation.add_where(column.to_s, value.to_s, "=")
              end
            end
            relation
          end

          def add_where_null(name, test)
            raise ArgumentError, "unknown column " + name unless #{@name}::COLUMNS.include?(name)
            @wheres << "#{@table.name}." + name + " " + test
          end

          def where_in(name, values)
            raise ArgumentError, "unknown column " + name unless #{@name}::COLUMNS.include?(name)
            relation = spawn
            relation.add_where_in(name, values)
            relation
          end

          def add_where_in(name, values)
            @wheres << "#{@table.name}." + name + " IN (" + values.map { |_| "?" }.join(", ") + ")"
            values.each { |v| @binds << v }
          end

          def with_includes(names)
            relation = spawn
            relation.add_includes(names)
            relation
          end

          def add_includes(names)
            names.each { |n| @include_names << n }
          end

          # An association reader hands over what includes(...) preloaded.
          def with_records(records)
            @records = records
            @loaded = true
            self
          end

          def where_not(conditions)
            relation = spawn
            conditions.each do |column, value|
              if value.nil?
                relation.add_where_null(column.to_s, "IS NOT NULL")
              else
                relation.add_where(column.to_s, value.to_s, "!=")
              end
            end
            relation
          end

          def add_where(name, value, op)
            raise ArgumentError, "unknown column " + name unless #{@name}::COLUMNS.include?(name)
            @wheres << "#{@table.name}." + name + " " + op + " ?"
            @binds << sql_value(name, value)
            if op == "="
              @scope_columns << name
              @scope_values << value
            end
          end

          # post.comments.build/create: the relation's equality conditions
          # become the new record's attributes.
          def apply_scope(record)
            i = 0
            while i < @scope_columns.length
              name = @scope_columns[i]
              value = @scope_values[i]
        #{indent(scope_assignments, 6)}
              i += 1
            end
            record
          end

          def build(#{create_kwargs})
            apply_scope(#{@name}.new(#{new_args}))
          end

          def create(#{create_kwargs})
            record = build(#{new_args})
            record.save
            record
          end

          def create!(#{create_kwargs})
            record = build(#{new_args})
            record.save!
            record
          end

          def build_from(params) = apply_scope(#{@name}.from_params(params))

          def create_from(params)
            record = build_from(params)
            record.save
            record
          end

          def create_from!(params)
            record = build_from(params)
            record.save!
            record
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
              relation.add_order("#{@table.name}." + name + " " + dir)
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
            return "#{@table.name}.id ASC" if @ordering.empty?
            @ordering.join(", ")
          end

          def joins_clause
            @join_names.map { |name| " " + #{@name}.join_sql(name) }.join
          end

          def with_joins(names)
            relation = spawn
            names.each { |n| relation.add_join(n) }
            relation
          end

          def add_join(name)
            @join_names << name
          end

          def distinct
            relation = spawn
            relation.set_distinct
            relation
          end

          def set_distinct
            @distinct = true
          end

          # where(authors: { name: "Ana" }) after joins(:author).
          def where_qualified(column, value)
            relation = spawn
            relation.add_qualified(column, value)
            relation
          end

          def add_qualified(column, value)
            @wheres << column + " = ?"
            @binds << value
          end

          def group_count(name)
            raise ArgumentError, "unknown column " + name unless #{@name}::COLUMNS.include?(name)
            t0 = Rieles.clock
            statement = "SELECT #{@table.name}." + name + ", COUNT(*) FROM #{@table.name}" + joins_clause + where_clause + " GROUP BY #{@table.name}." + name
            db = Rieles.prepare(statement, false)
            bind_all(db)
            counts = { "" => 0 }
            counts.delete("")
            while db.step == 1
              counts[db.col_str(0)] = db.col_int(1)
            end
            db.finalize
            Rieles.log.sql_binds(#{"#{@name} Count".inspect}, statement, t0, @binds)
            counts
          end

          def where_clause
            @wheres.empty? ? "" : " WHERE " + @wheres.join(" AND ")
          end

          def sql(select)
            statement = "SELECT " + (@distinct ? "DISTINCT " : "") + select + " FROM #{@table.name}" + joins_clause + where_clause + " ORDER BY " + order_clause
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
            statement = sql(#{select_list.inspect})
            db = Rieles.prepare(statement, false)
            bind_all(db)
            while db.step == 1
              @records << #{@name}.from_row(db)
            end
            db.finalize
            Rieles.log.sql_binds(#{"#{@name} Load".inspect}, statement, t0, @binds)
            @loaded = true
            @include_names.each { |name| #{@name}.preload_association(@records, name) }
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
            @ordering = ["#{@table.name}.id ASC"] if @ordering.empty?
            @ordering = @ordering.map { |c| c.end_with?(" ASC") ? c.sub(" ASC", " DESC") : c.sub(" DESC", " ASC") }
          end

          def count
            return @records.length if @loaded
            return to_a.length if @limit_value >= 0 || @offset_value >= 0
            t0 = Rieles.clock
            statement = "SELECT COUNT(" + (@distinct ? "DISTINCT #{@table.name}.id" : "*") + ") FROM #{@table.name}" + joins_clause + where_clause
            db = Rieles.prepare(statement, false)
            bind_all(db)
            n = db.step == 1 ? db.col_int(0) : 0
            db.finalize
            Rieles.log.sql_binds(#{"#{@name} Count".inspect}, statement, t0, @binds)
            n
          end

          def exists?
            return !@records.empty? if @loaded
            limit(1).to_a.length > 0
          end

          def update_all(changes)
            raise ArgumentError, "update_all doesn't support joins" unless @join_names.empty?
            t0 = Rieles.clock
            sets = []
            values = []
            changes.each do |column, value|
              name = column.to_s
              raise ArgumentError, "unknown column " + name unless #{@name}::COLUMNS.include?(name)
              sets << name + " = ?"
              values << sql_value(name, value.to_s)
            end
            statement = "UPDATE #{@table.name} SET " + sets.join(", ") + where_clause
            db = Rieles.prepare(statement, false)
            i = 0
            while i < values.length
              db.bind_str(i + 1, values[i])
              i += 1
            end
            j = 0
            while j < @binds.length
              db.bind_str(values.length + j + 1, @binds[j])
              j += 1
            end
            Rieles.write(db, #{"#{@name} Update All".inspect}, statement, t0)
          end

        #{indent(scope_methods, 2)}

          def delete_all
            raise ArgumentError, "delete_all doesn't support joins" unless @join_names.empty?
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

          def to_json = to_a.to_json
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
