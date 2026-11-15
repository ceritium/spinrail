module Spinrail
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

    attr_reader :name, :file, :sti_base, :sti_children, :rich_texts

    def initialize(file, schema, sti_base: nil, build: nil, source: nil, table: nil)
      @build = build
      @file = file
      @sti_base = sti_base
      @sti_children = []
      @schema = schema
      source ||= File.read(file)
      klass = Spinrail.parse(source, file).statements.body.find { |n| n.is_a?(Prism::ClassNode) }
      raise CompileError, "#{file}: expected a class" unless klass
      @name = klass.constant_path.slice
      @parent = klass.superclass&.slice || "ApplicationRecord"
      table_name = table || Inflector.tableize(sti_base || @name)
      @table = schema.table(table_name) or
        raise CompileError, "#{file}: no `create_table :#{table_name}` in db/schema.rb"
      if sti_base && !@table.column("type")
        raise CompileError, "#{file}: #{@name} < #{sti_base} needs a `type` column on #{table_name}"
      end
      @validations = []
      @custom_validations = []
      @callbacks = Hash.new { |h, k| h[k] = [] }
      @associations = []
      @through = []
      @scopes = []
      @enums = {}
      @extra_virtual = []
      @body = []
      @relation_methods = []
      @constants = []
      @rich_texts = []
      (klass.body&.body || []).each { |stmt| collect(stmt) }
    end

    def to_ruby
      return sti_child_class if @sti_base
      [model_class, relation_class].join("\n")
    end

    # Subclass callbacks and validations run through hooks the base calls
    # and the subclass overrides.
    def sti_children=(children)
      @sti_children = children
      return if children.empty?
      raise CompileError, "#{@file}: #{@name} has subclasses but no `type` column" unless @table.column("type")
      @sti_hooks = children.flat_map { |c| c.sti_hook_kinds }.uniq
      @sti_hooks.each do |kind|
        kind == :validate ? @custom_validations << "sti_validate" : @callbacks[kind] << "sti_#{kind}"
      end
    end

    # A row whose type names a subclass becomes an instance of it.
    def sti_from_row(args)
      return [] if @sti_children.empty?
      i = columns.index { |c| c.name == "type" }
      ["sti_type = #{columns[i].read(i)}"] +
        @sti_children.map { |c| "return #{c.name}.new(#{args.join(', ')}) if sti_type == #{c.name.inspect}" }
    end

    # sti_name is what new records store in type; becomes_x (from
    # becomes/becomes!) copies the record into another class of the hierarchy.
    def sti_base_methods
      return [] if @sti_children.empty?
      becomes = ([@name] + @sti_children.map(&:name)).map do |klass|
        args = columns.map { |c| "#{c.name}: #{c.name == 'type' ? klass.inspect : "@#{c.name}"}" }.join(", ")
        "def #{Model.becomes_method(klass)} = #{klass}.new(#{args})"
      end
      ["def sti_name = @type", *@sti_hooks.map { |k| "def sti_#{k} = nil" }, *becomes]
    end

    def self.becomes_method(klass) = "becomes_#{Inflector.underscore(klass).tr('/', '_')}"

    def sti_child_class
      namespaces = @name.split("::")[0..-2]
      modules = namespaces.each_index.map { |i| "module #{namespaces[0..i].join('::')}\nend\n" }
      hooks = @callbacks.reject { |_, calls| calls.empty? }.map { |kind, _| "def sti_#{kind}\n#{indent(run_callbacks(kind), 2)}\nend" }
      hooks << "def sti_validate\n#{indent(sti_checks, 2)}\nend" unless sti_checks.empty?
      <<~RUBY
        #{modules.join}class #{@name} < #{@sti_base}
          def self.all = #{@sti_base}Relation.new.where(type: #{@name.inspect})
          def sti_name = #{@name.inspect}

        #{indent(hooks, 2)}

        #{indent(user_methods, 2)}
        end
      RUBY
    end

    def sti_hook_kinds = @callbacks.reject { |_, calls| calls.empty? }.keys + (sti_checks.empty? ? [] : [:validate])

    def sti_checks
      checks = @validations.map do |attr, cond, (key, text, count)|
        message = key ? "Spinrail.message(#{key.inspect}, #{text.inspect}, #{count.inspect})" : text.inspect
        "@errors.add(:#{attr}, #{message}) if #{cond}"
      end
      checks + @custom_validations
    end

    private

    STI_UNSUPPORTED = %i[has_many has_one belongs_to scope enum has_secure_password has_secure_token has_rich_text].freeze

    def collect(stmt)
      call = stmt.is_a?(Prism::CallNode) && stmt.receiver.nil? ? stmt.name : nil
      if @sti_base && STI_UNSUPPORTED.include?(call)
        fail!(stmt, "#{call} in a subclass is not supported yet; declare it on #{@sti_base}")
      end
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
      elsif call == :enum
        enum(stmt)
      elsif call == :has_secure_password
        fail!(stmt, "has_secure_password needs a password_digest column") unless @table.column("password_digest")
        @secure_password = true
        _, kw = Spinrail.call_args(stmt)
        @secure_password_validations = !(kw[:validations] && Spinrail.literal(kw[:validations]) == false)
      elsif call == :has_secure_token
        secure_token(stmt)
      elsif call == :has_rich_text
        rich_text(stmt)
      elsif stmt.is_a?(Prism::SingletonClassNode)
        singleton_class_body(stmt)
      else
        source = stmt.slice.gsub(/^ {#{stmt.location.start_column}}/, "")
        @body << source
        # Class methods also run on a relation, scoped to it, as in Rails.
        @constants << stmt.name.to_s if stmt.is_a?(Prism::ConstantWriteNode)
        @relation_methods << source.sub(/\Adef self\./, "def ") if !@sti_base && stmt.is_a?(Prism::DefNode) && stmt.receiver.is_a?(Prism::SelfNode)
      end
    end

    # class << self: each def is a def self.x; private ones stay off relations.
    def singleton_class_body(node)
      fail!(node, "only class << self is supported") unless node.expression.is_a?(Prism::SelfNode)
      visible = true
      (node.body&.body || []).each do |stmt|
        if stmt.is_a?(Prism::CallNode) && stmt.receiver.nil? && %i[private public].include?(stmt.name) && stmt.arguments.nil?
          visible = stmt.name == :public
        elsif stmt.is_a?(Prism::DefNode) && stmt.receiver.nil?
          source = "def self." + stmt.slice.gsub(/^ {#{stmt.location.start_column}}/, "").delete_prefix("def ")
          @body << source
          @relation_methods << source.sub(/\Adef self\./, "def ") if visible && !@sti_base
        else
          fail!(stmt, "class << self supports only def, private and public")
        end
      end
    end

    # has_secure_token [:attr]: a random token set before create (Rails'
    # default, not on: :initialize), plus regenerate_<attr>.
    def secure_token(node)
      args, kw = Spinrail.call_args(node)
      fail!(node, "unsupported has_secure_token option #{kw.keys.first}") if kw.any?
      attr = args.empty? ? "token" : Spinrail.literal(args.first).to_s
      fail!(node, "has_secure_token needs the #{attr} column") unless @table.column(attr)
      @callbacks[:before_create] << "@#{attr} = SecureRandom.alphanumeric(24) if @#{attr}.to_s.empty?"
      @body << "def regenerate_#{attr} = update!(#{attr}: SecureRandom.alphanumeric(24))"
    end

    # has_rich_text :body: an ActionText::RichText row per record, loaded
    # on first read and saved after the record.
    def rich_text(node)
      args, kw = Spinrail.call_args(node)
      fail!(node, "unsupported has_rich_text option #{kw.keys.first}") if kw.any?
      attr = Spinrail.literal(args.first).to_s
      fail!(node, "has_rich_text :#{attr} clashes with the #{attr} column") if @table.column(attr)
      unless @schema.table("action_text_rich_texts")
        fail!(node, "has_rich_text needs the action_text_rich_texts table (bin/rails action_text:install's migration)")
      end
      @rich_texts << attr
      @callbacks[:after_save] << "save_rich_text_#{attr}"
      @callbacks[:after_destroy] << "ActionText::RichText.where(record_type: #{@name.inspect}, record_id: @id).delete_all" if @rich_texts.size == 1
      @body << <<~RUBY.chomp
        def #{attr}
          unless @rich_#{attr}_loaded
            @rich_#{attr} = ActionText::RichText.find_for(#{@name.inspect}, @id, #{attr.inspect})
            @rich_#{attr}_loaded = true
          end
          @rich_#{attr}
        end

        def #{attr}=(html)
          #{attr}.body = html.to_s
          @rich_#{attr}_changed = true
        end

        def save_rich_text_#{attr}
          return unless @rich_#{attr}_changed
          rich = #{attr}
          rich.record_id = @id
          rich.save!
          @rich_#{attr}_changed = false
        end
      RUBY
      @body << "def self.with_rich_text_#{attr} = all"
      @relation_methods << "def with_rich_text_#{attr} = self"
    end

    # before_save :x, if: :y -> "x if y"
    def guarded_calls(node)
      args, kw = Spinrail.call_args(node)
      guard = guard(node, kw)
      args.map { |a| guard ? "#{Spinrail.literal(a)} if #{guard}" : Spinrail.literal(a).to_s }
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
        on = Spinrail.literal(kw[:on])
        fail!(node, "on: takes :create or :update") unless %i[create update].include?(on)
        parts << (on == :create ? "!persisted?" : "persisted?")
      end
      parts.empty? ? nil : parts.join(" && ")
    end

    def association(node)
      args, kw = Spinrail.call_args(node)
      name = Spinrail.literal(args.first).to_s
      default = kw.delete(:default)
      opts = kw.transform_values { |v| Spinrail.literal(v) }
      return through(node, name, opts) if node.name == :has_many && opts[:through]
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
      belongs_to_default(node, fk, default) if default
      @associations << Association.new(node.name, name, class_name, fk, dependent, opts[:optional])
    end

    # belongs_to :creator, default: -> { Current.user }: filled in on
    # create when the foreign key is unset.
    def belongs_to_default(node, fk, default)
      fail!(node, "belongs_to default: takes a lambda") unless default.is_a?(Prism::LambdaNode) && default.parameters.nil?
      fail!(node, "default: is for belongs_to") unless node.name == :belongs_to
      body = default.body&.slice or fail!(node, "default: lambda is empty")
      @callbacks[:before_validation].unshift(
        "if !persisted? && @#{fk}.to_i == 0\n  default_record = (#{body})\n  @#{fk} = default_record.id if default_record\nend"
      )
    end

    # has_many :users, through: :memberships: one hop over a has_many whose
    # model holds user_id (or source:'s _id), as a subquery.
    def through(node, name, opts)
      unknown = opts.keys - %i[through source class_name]
      fail!(node, "unsupported has_many through option #{unknown.first}") if unknown.any?
      via = @associations.find { |a| a.kind == :has_many && a.name == opts[:through].to_s } or
        fail!(node, "has_many :#{name} goes through :#{opts[:through]}, declare that has_many first")
      source = (opts[:source] || Inflector.singularize(name)).to_s
      join_table = @schema.table(Inflector.tableize(via.class_name))
      fail!(node, "#{join_table.name} has no #{source}_id column") unless join_table.column("#{source}_id")
      class_name = opts[:class_name] || Inflector.camelize(source)
      fail!(node, "no table #{Inflector.tableize(class_name)} for #{class_name}") unless @schema.table(Inflector.tableize(class_name))
      sql = "SELECT #{source}_id FROM #{join_table.name} WHERE #{via.foreign_key} = ?"
      @through << "def #{name} = #{class_name}.all.where_subquery(\"id\", #{sql.inspect}, @id.to_s)"
    end

    # scope :published, -> { where(published: true) } becomes a relation
    # method (so scopes chain) and a class method.
    def scope(node)
      args, = Spinrail.call_args(node)
      name = Spinrail.literal(args[0]).to_s
      lambda = args[1]
      fail!(node, "scope :name, -> { ... }") unless lambda.is_a?(Prism::LambdaNode)
      params = lambda.parameters&.parameters&.requireds&.map(&:name) || []
      body = lambda.body ? lambda.body.slice : "self"
      @scopes << [name, params, body]
    end

    # enum :status, { draft: 0, published: 1 } (or enum status: {...}) on an
    # integer column; on a string one each name maps to itself, as Campfire's
    # %w[...].index_by(&:itself). prefix:/suffix: as in Rails.
    Enum = Struct.new(:mapping, :string, :prefix, :suffix) do
      def method_name(column, value)
        affix = ->(a) { a == true ? column : a&.to_s }
        [affix.(prefix), value, affix.(suffix)].compact.join("_")
      end
    end

    def enum(node)
      args, kw = Spinrail.call_args(node)
      name, values = args[0] ? [Spinrail.literal(args[0]).to_s, args[1]] : [kw.keys.first.to_s, kw.delete(kw.keys.first)]
      opts = kw.transform_values { |v| Spinrail.literal(v) }
      unknown = opts.keys - %i[prefix suffix]
      fail!(node, "unsupported enum option #{unknown.first}") if unknown.any?
      mapping = Spinrail.literal(values)
      index = @table.columns.index { |c| c.name == name } or fail!(node, "enum :#{name} needs a column #{name}")
      column = @table.columns[index]
      string = column.type == :string || column.type == :text
      fail!(node, "enum :#{name} needs an integer or string column") unless string || column.integer?
      if string
        mapping = mapping.to_h { |v| [v, v] } if mapping.is_a?(Array)
        mapping = mapping.to_h { |k, v| [k.to_s, v.to_s] }
        fail!(node, "enum :#{name} on a string column stores each name as itself") unless mapping.all? { |k, v| k == v }
      else
        mapping = mapping.each_with_index.to_h { |v, i| [v, i] } if mapping.is_a?(Array)
        mapping = mapping.to_h { |k, v| [k.to_s, v] }
        @table.columns[index] = EnumColumn.from(column, mapping)
      end
      @enums[name] = Enum.new(mapping, string, opts[:prefix], opts[:suffix])
      allow_nil = string && column.null ? "!@#{name}.nil? && " : ""
      @validations << [name, "#{allow_nil}!#{mapping.keys.inspect}.include?(@#{name})", ["inclusion", "is not included in the list", ""]]
    end

    def enum_methods
      @enums.flat_map do |column, enum|
        enum.mapping.keys.flat_map do |value|
          method = enum.method_name(column, value)
          ["def #{method}? = @#{column} == #{value.inspect}", "def #{method}! = update(#{column}: #{value.inspect})"]
        end + ["def self.#{Inflector.pluralize(column)} = #{enum.mapping.inspect}"] +
          enum.mapping.keys.map { |value| "def self.#{enum.method_name(column, value)} = all.where(#{column}: #{value.inspect})" }
      end
    end

    def enum_relation_methods
      @enums.flat_map do |column, enum|
        enum.mapping.keys.map { |value| "def #{enum.method_name(column, value)} = where(#{column}: #{value.inspect})" }
      end
    end

    def validates(node)
      args, kw = Spinrail.call_args(node)
      @guard = guard(node, kw.slice(:if, :unless, :on))
      kw = kw.reject { |k, _| %i[if unless on].include?(k) }
      args.each do |arg|
        attr = Spinrail.literal(arg).to_s
        assoc = @associations.find { |a| a.kind == :belongs_to && a.name == attr }
        if assoc
          kw.each_key { |k| fail!(node, "only presence is supported on #{attr}") unless k == :presence }
          @validations << [attr, guarded("!#{assoc.class_name}.where(id: @#{assoc.foreign_key}).exists?"), ["required", "must exist", ""]]
          next
        end
        rules = kw.dup
        if rules.key?(:acceptance) && !@table.column(attr)
          @extra_virtual << attr unless @extra_virtual.include?(attr)
          @validations << [attr, guarded("@#{attr} != \"1\" && @#{attr} != \"true\""), ["accepted", "must be accepted", ""]]
          rules.delete(:acceptance)
          next if rules.empty?
        end
        column = @table.column(attr) or fail!(node, "unknown attribute #{attr}")
        if rules.delete(:confirmation)
          confirmation = "#{attr}_confirmation"
          @extra_virtual << confirmation unless @extra_virtual.include?(confirmation)
          @validations << [confirmation, guarded("!@#{confirmation}.empty? && @#{confirmation} != @#{attr}.to_s"),
                           ["confirmation", "doesn't match #{Inflector.humanize(attr)}", ""]]
        end
        rules.each { |kind, value_node| validation(node, column, kind, value_node) }
      end
      @guard = nil
    end

    def guarded(cond) = @guard ? "(#{@guard}) && (#{cond})" : cond

    def validation(node, column, kind, value_node)
      attr = column.name
      ivar = "@#{attr}"
      value = value_node.is_a?(Prism::HashNode) ? value_node.elements.to_h { |a| [Spinrail.literal(a.key), a.value] } : {}
      message = value[:message] && Spinrail.literal(value[:message])
      add = ->(cond, key, text, count = "") { @validations << [attr, guarded(cond), message ? [nil, message, ""] : [key, text, count.to_s]] }
      case kind
      when :presence
        if column.string?
          add.("#{column.null ? "#{ivar}.nil? || " : ''}#{ivar}.strip.empty?", "blank", "can't be blank") if Spinrail.literal(value_node)
        elsif column.null
          add.("#{ivar}.nil?", "blank", "can't be blank") if Spinrail.literal(value_node)
        else
          fail!(node, "presence on a NOT NULL #{column.type} column is always true")
        end
      when :length
        fail!(node, "length only applies to string columns") unless column.string?
        ivar = "#{ivar}.to_s" if column.null
        { maximum: [">", "too_long", "is too long (maximum is %{count} characters)"],
          minimum: ["<", "too_short", "is too short (minimum is %{count} characters)"],
          is: ["!=", "wrong_length", "is the wrong length (should be %{count} characters)"] }.each do |key, (op, i18n, msg)|
          next unless value[key]
          n = Spinrail.literal(value[key])
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

    # Qualified with the table so joins can't make them ambiguous.
    def select_list = columns.map { |c| "#{@table.name}.#{c.name}" }.join(", ")
    def relation = "#{@name}Relation"

    def param_assignments
      writable.map do |c|
        read = "params.get(#{c.name.inspect})"
        value = case c.type
                when :integer then c.null ? "(#{read}.empty? ? nil : #{read}.to_i)" : "#{read}.to_i"
                when :float then c.null ? "(#{read}.empty? ? nil : #{read}.to_f)" : "#{read}.to_f"
                when :boolean then "(#{read} == \"1\" || #{read} == \"true\" || #{read} == \"on\")"
                when :datetime then c.null ? "(#{read}.empty? ? nil : Spinrail.parse_local(#{read}))" : "Spinrail.parse_local(#{read})"
                else read
                end
        "@#{c.name} = #{value} if params.has?(#{c.name.inspect})"
      end + (virtual + @rich_texts).map { |v| "self.#{v} = params.get(#{v.inspect}) if params.has?(#{v.inspect})" }
    end

    # has_secure_password: password and password_confirmation aren't columns.
    def virtual = (@secure_password ? %w[password password_confirmation] : []) + @extra_virtual

    def rich_kwargs = @rich_texts.map { |r| "#{r}: nil" }
    def rich_assign = @rich_texts.map { |r| "self.#{r} = #{r} unless #{r}.nil?" }

    def inspect_fields
      columns.map do |c|
        c.name == "password_digest" ? %("#{c.name}: [FILTERED]") : %("#{c.name}: " + @#{c.name}.inspect)
      end.join(%( + ", " + ))
    end

    def json_fields = columns.reject { |c| c.name == "password_digest" }.map { |c| "#{%("#{c.name}":).inspect} + @#{c.name}.to_json" }.join(%( + "," + ))

    def insert_sql
      cols = writable + columns.select(&:timestamp?)
      "INSERT INTO #{@table.name} (#{cols.map(&:name).join(', ')}) VALUES (#{(["?"] * cols.size).join(', ')})"
    end

    def update_sql
      sets = writable.map { |c| "#{c.name} = ?" }
      sets << "updated_at = ?" if @table.column("updated_at")
      "UPDATE #{@table.name} SET #{sets.join(', ')} WHERE id = ?"
    end

    # authenticate_by(email_address: e, password: p): the record or nil. A
    # miss still hashes, so its timing doesn't tell which emails exist.
    def authenticate_by_method
      return "" unless @secure_password
      <<~RUBY
        def authenticate_by(conditions)
          password = conditions[:password]
          raise ArgumentError, "authenticate_by needs password:" if password.nil?
          relation = spawn
          blank = password.empty?
          conditions.each do |column, value|
            next if column == :password
            blank = true if value.nil? || value.to_s.empty?
            relation.add_where(column.to_s, Spinrail.sql_text(value), "=")
          end
          record = blank ? nil : relation.first
          if record.nil?
            Tep::Password.hash(password)
            return nil
          end
          record.authenticate(password) ? record : nil
        end
      RUBY
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
        "t0 = Spinrail.clock",
        "db = Spinrail.prepare(#{sql.inspect}, true)",
        *binds,
        "Spinrail.write(db, #{"#{@name} #{label}".inspect}, #{sql.inspect}, t0)"
      ].join("\n")
    end

    def save_method
      timestamps = columns.select(&:timestamp?).map(&:name)
      stamp = timestamps.empty? ? "" : "now = Spinrail.now\n"
      insert_stamps = timestamps.map { |t| "db.bind_str(%d, Spinrail.format_time(now))" }
      create = [stamp + run_callbacks(:before_create), write_statement(insert_sql, "Create", writable, insert_stamps),
                "@id = db.last_rowid", *timestamps.map { |t| "@#{t} = now" }, run_callbacks(:after_create)]
      update_stamps = @table.column("updated_at") ? ["db.bind_str(%d, Spinrail.format_time(now))"] : []
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

        def destroy!
          raise Spinrail::RecordNotDestroyed, "Failed to destroy #{@name} with id=" + @id.to_s unless destroy
          self
        end
      RUBY
    end

    # Readers use what includes(...) preloaded, else query.
    def association_methods
      @through + @associations.map do |a|
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
      Lowering.lower(source, @file, Build::Context.new(@build, "", view: false, model: @name))
    end

    def model_class
      kwargs = (columns.map { |c| "#{c.name}: #{c.default_literal}" } + virtual.map { |v| "#{v}: \"\"" } + rich_kwargs).join(", ")
      update_kwargs = (assignable.map { |c| "#{c.name}: @#{c.name}" } + virtual.map { |v| "#{v}: \"\"" } + rich_kwargs).join(", ")
      assign = assignable.map { |c| "@#{c.name} = #{c.name}" } + secure_assign + rich_assign
      from_row = columns.each_with_index.map { |c, i| "#{c.name}: #{c.read(i)}" }
      checks = (@validations + required_associations + secure_validations).map do |attr, cond, (key, text, count)|
        message = key ? "Spinrail.message(#{key.inspect}, #{text.inspect}, #{count.inspect})" : text.inspect
        "@errors.add(:#{attr}, #{message}) if #{cond}"
      end
      plucks = columns.map { |c| "def self.pluck_#{c.name} = all.pluck_#{c.name}" }
      predicates = columns.select(&:boolean?).map { |c| "def #{c.name}? = @#{c.name}" }
      <<~RUBY
        class #{@name} < #{@parent}
          COLUMNS = #{columns.map(&:name).inspect}
          attr_accessor #{columns.map { |c| ":#{c.name}" }.join(', ')}
          attr_reader :errors
        #{@extra_virtual.empty? ? '' : "  attr_accessor #{@extra_virtual.map { |v| ":#{v}" }.join(', ')}\n"}        #{@secure_password ? "  attr_reader :password\n  attr_accessor :password_confirmation\n\n  def password=(plain)\n    @password = plain\n    @password_digest = Tep::Password.hash(plain) unless plain.empty?\n  end\n\n  # true or false (Rails returns the record or false).\n  def authenticate(plain) = !@password_digest.to_s.empty? && Tep::Password.verify(plain, @password_digest)\n" : ""}
          def initialize(#{kwargs})
        #{indent(columns.map { |c| "@#{c.name} = #{c.name}" }, 4)}
        #{indent((@secure_password ? ["@password = \"\"", *secure_assign] : []) + @extra_virtual.map { |v| "@#{v} = #{v}" }, 4)}
            @errors = Spinrail::Errors.new(#{Inflector.underscore(@name).inspect})
        #{indent(@rich_texts.flat_map { |r| ["@rich_#{r} = ActionText::RichText.new", "@rich_#{r}_loaded = false", "@rich_#{r}_changed = false"] } + rich_assign, 4)}
        #{@sti_children.empty? ? '' : "    @type = sti_name\n"}        #{indent(@associations.map { |a| "@preloaded_#{a.name} = false" }, 4)}
          end

          def self.from_row(db)
        #{indent(sti_from_row(from_row), 4)}
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
          def self.find_by!(conditions) = all.find_by!(conditions)
          #{@secure_password ? "def self.authenticate_by(conditions) = all.authenticate_by(conditions)" : ""}
          def self.update_all(changes) = all.update_all(changes)
          def self.with_includes(names) = all.with_includes(names)
          def self.with_joins(names) = all.with_joins(names)
          def self.distinct = all.distinct
          def self.page(number) = all.page(number)
          def self.where_qualified(column, value) = all.where_qualified(column, value)
          def self.group_count(name) = all.group_count(name)
        #{indent(join_sql_method, 2)}
        #{indent(preload_method, 2)}
        #{indent(@scopes.map { |n, ps, _| sig = ps.empty? ? '' : "(#{ps.join(', ')})"; "def self.#{n}#{sig} = all.#{n}#{sig}" }, 2)}
        #{indent(plucks, 2)}

          def self.find(id)
            record = where(id: id.to_s.to_i).first
            raise Spinrail::RecordNotFound, "Couldn't find #{@name} with 'id'=" + id.to_s unless record
            record
          end

          def self.create(#{create_kwargs})
            record = new(#{new_args})
            record.save
            record
          end

          def self.create!(#{create_kwargs})
            record = new(#{new_args})
            record.save!
            record
          end

          def self.transaction
            Spinrail.transaction { yield }
          end

        #{indent(enum_methods, 2)}
          def to_param = @id.to_s
          def to_stream_name = #{"#{@table.name}/".inspect} + @id.to_s
          def cache_key = #{"#{@table.name}/".inspect} + @id.to_s#{@table.column("updated_at") ? ' + "-" + @updated_at.strftime("%Y%m%d%H%M%S%6N")' : ''}
          def dom_id = @id > 0 ? #{"#{Inflector.underscore(@name)}_".inspect} + @id.to_s : #{"new_#{Inflector.underscore(@name)}".inspect}
          def dom_id_with(prefix) = @id > 0 ? prefix + #{"_#{Inflector.underscore(@name)}_".inspect} + @id.to_s : prefix + #{"_#{Inflector.underscore(@name)}".inspect}
          def persisted? = @id > 0
          def new_record? = @id == 0
        #{indent(sti_base_methods, 2)}
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
            raise Spinrail::RecordInvalid, "Validation failed: " + @errors.full_messages.join(", ") unless save
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
            record = new
            record.assign_params(params)
            record
          end

          def self.create_from(params)
            record = from_params(params)
            record.save
            record
          end

          def self.create_from!(params)
            record = from_params(params)
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

          def inspect
            "#<#{@name} " + #{inspect_fields} + ">"
          end

          def reload
            fresh = #{@name}.find(@id)
        #{indent(assignable.map { |c| "@#{c.name} = fresh.#{c.name}" } + @rich_texts.map { |r| "@rich_#{r}_loaded = false" }, 4)}
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
      [Lowering.lower(source, @file, Build::Context.new(nil, "", view: false, relation: true))]
    end

    # Scope bodies run in the relation class, so they see the model's constants.
    def relation_constants = @constants.map { |c| "#{c} = #{@name}::#{c}" }

    def relation_methods
      return [] if @relation_methods.empty?
      [Lowering.lower(@relation_methods.join("\n\n"), @file, Build::Context.new(nil, "", view: false, relation: true))]
    end

    def create_kwargs = (assignable.map { |c| "#{c.name}: #{c.default_literal}" } + virtual.map { |v| "#{v}: \"\"" } + rich_kwargs).join(", ")
    def new_args = (assignable.map(&:name) + virtual + @rich_texts).map { |n| "#{n}: #{n}" }.join(", ")

    def secure_assign
      extra = @extra_virtual.map { |v| "@#{v} = #{v}" }
      return extra unless @secure_password
      ["self.password = password unless password.empty?", "@password_confirmation = password_confirmation"] + extra
    end

    def secure_validations
      return [] unless @secure_password && @secure_password_validations
      [["password", "@password_digest.to_s.empty?", ["blank", "can't be blank", ""]],
       ["password_confirmation", "!@password_confirmation.empty? && @password_confirmation != @password",
        ["confirmation", "doesn't match Password", ""]]]
    end

    def scope_assignments
      assignable.map do |c|
        value = case c.type
                when :integer then "value.to_i"
                when :float then "value.to_f"
                when :boolean then 'value == "1"'
                when :datetime then "Spinrail.parse_time(value)"
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
      enum_values = @enums.reject { |_, enum| enum.string }.map do |column, enum|
        "return #{EnumColumn.from(@table.column(column), enum.mapping).to_int('value')}.to_s if name == #{column.inspect}"
      end
      bool_value = (enum_values + [bool_value]).join("\n")
      plucks = columns.each_with_index.map do |c, _|
        <<~RUBY
          def pluck_#{c.name}
            return @records.map { |r| r.#{c.name} } if @loaded
            t0 = Spinrail.clock
            statement = sql(#{"#{@table.name}.#{c.name}".inspect})
            db = Spinrail.prepare(statement, false)
            bind_all(db)
            values = []
            while db.step == 1
              values << #{c.read(0)}
            end
            db.finalize
            Spinrail.log.sql_binds(#{"#{@name} Pluck".inspect}, statement, t0, @binds)
            values
          end
        RUBY
      end
      <<~RUBY
        class #{relation}
          attr_reader :wheres, :binds, :ordering, :raw_order, :limit_value, :offset_value, :scope_columns, :scope_values,
                      :include_names, :join_names, :page_number, :per_page

          def initialize
            @wheres = []
            @binds = []
            @scope_columns = []
            @scope_values = []
            @include_names = []
            @join_names = []
            @page_number = 0
            @per_page = 25
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
            @page_number = other.page_number
            @per_page = other.per_page
            @distinct = other.distinct?
            @ordering = other.ordering.dup
            @raw_order = other.raw_order
            @limit_value = other.limit_value
            @offset_value = other.offset_value
            self
          end

          def spawn = #{relation}.new.restore(self)
          def all = spawn

          # page(params[:page]).per(10): 25 per page unless per says otherwise.
          def page(number)
            relation = spawn
            n = number.to_s.to_i
            relation.set_page(n < 1 ? 1 : n, @per_page)
            relation
          end

          def per(n)
            relation = spawn
            relation.set_page(@page_number < 1 ? 1 : @page_number, n)
            relation
          end

          def set_page(number, size)
            @page_number = number
            @per_page = size
            @limit_value = size
            @offset_value = (number - 1) * size
          end

          def current_page = @page_number < 1 ? 1 : @page_number

          def total_pages
            unpaged = spawn
            unpaged.set_limit(-1)
            unpaged.set_offset(-1)
            total = unpaged.count
            pages = (total + @per_page - 1) / @per_page
            pages < 1 ? 1 : pages
          end
        #{indent(enum_relation_methods, 2)}
          def distinct? = @distinct

          def where(conditions)
            relation = spawn
            conditions.each do |column, value|
              if value.nil?
                relation.add_where_null(column.to_s, "IS NULL")
              else
                relation.add_where(column.to_s, Spinrail.sql_text(value), "=")
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
                relation.add_where(column.to_s, Spinrail.sql_text(value), "!=")
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

          def where_subquery(name, select, value)
            relation = spawn
            relation.add_where_subquery(name, select, value)
            relation
          end

          def add_where_subquery(name, select, value)
            @wheres << "#{@table.name}." + name + " IN (" + select + ")"
            @binds << value
          end

          def add_qualified(column, value)
            @wheres << column + " = ?"
            @binds << value
          end

          def group_count(name)
            raise ArgumentError, "unknown column " + name unless #{@name}::COLUMNS.include?(name)
            t0 = Spinrail.clock
            statement = "SELECT #{@table.name}." + name + ", COUNT(*) FROM #{@table.name}" + joins_clause + where_clause + " GROUP BY #{@table.name}." + name
            db = Spinrail.prepare(statement, false)
            bind_all(db)
            counts = { "" => 0 }
            counts.delete("")
            while db.step == 1
              counts[db.col_str(0)] = db.col_int(1)
            end
            db.finalize
            Spinrail.log.sql_binds(#{"#{@name} Count".inspect}, statement, t0, @binds)
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
            t0 = Spinrail.clock
            statement = sql(#{select_list.inspect})
            db = Spinrail.prepare(statement, false)
            bind_all(db)
            while db.step == 1
              @records << #{@name}.from_row(db)
            end
            db.finalize
            Spinrail.log.sql_binds(#{"#{@name} Load".inspect}, statement, t0, @binds)
            @loaded = true
            @include_names.each { |name| #{@name}.preload_association(@records, name) }
            @records
          end

          def first
            return to_a.first if @loaded
            limit(1).to_a.first
          end

          def find_by(conditions) = where(conditions).first

          def find_by!(conditions)
            record = find_by(conditions)
            raise Spinrail::RecordNotFound, "Couldn't find #{@name}" unless record
            record
          end

          # last(n), lowered from scope bodies: the last n rows in order.
          def last_n(n)
            raise ArgumentError, "last needs an order by column, not SQL" if @raw_order.length > 0
            relation = spawn
            relation.reverse_order
            relation.set_limit(n)
            relation.to_a.reverse
          end
        #{indent(authenticate_by_method, 2)}

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
            t0 = Spinrail.clock
            statement = "SELECT COUNT(" + (@distinct ? "DISTINCT #{@table.name}.id" : "*") + ") FROM #{@table.name}" + joins_clause + where_clause
            db = Spinrail.prepare(statement, false)
            bind_all(db)
            n = db.step == 1 ? db.col_int(0) : 0
            db.finalize
            Spinrail.log.sql_binds(#{"#{@name} Count".inspect}, statement, t0, @binds)
            n
          end

          def exists?
            return !@records.empty? if @loaded
            limit(1).to_a.length > 0
          end

          def update_all(changes)
            raise ArgumentError, "update_all doesn't support joins" unless @join_names.empty?
            t0 = Spinrail.clock
            sets = []
            values = []
            changes.each do |column, value|
              name = column.to_s
              raise ArgumentError, "unknown column " + name unless #{@name}::COLUMNS.include?(name)
              sets << name + " = ?"
              values << sql_value(name, value.to_s)
            end
            statement = "UPDATE #{@table.name} SET " + sets.join(", ") + where_clause
            db = Spinrail.prepare(statement, false)
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
            Spinrail.write(db, #{"#{@name} Update All".inspect}, statement, t0)
          end

        #{indent(relation_constants, 2)}
        #{indent(scope_methods, 2)}
        #{indent(relation_methods, 2)}

          def delete_all
            raise ArgumentError, "delete_all doesn't support joins" unless @join_names.empty?
            t0 = Spinrail.clock
            statement = "DELETE FROM #{@table.name}" + where_clause
            db = Spinrail.prepare(statement, false)
            bind_all(db)
            Spinrail.write(db, #{"#{@name} Delete All".inspect}, statement, t0)
          end

        #{indent(plucks, 2)}

          def each
            to_a.each { |record| yield record }
          end

          def each_with_index
            to_a.each_with_index { |record, i| yield record, i }
          end

          def to_json = to_a.to_json
          def inspect = to_a.inspect
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
