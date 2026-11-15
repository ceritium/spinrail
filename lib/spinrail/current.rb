module Spinrail
  # class Current < ActiveSupport::CurrentAttributes: one instance per
  # fiber slot (Rails isolates per thread or fiber), reset before each
  # request, job and model test. Class methods delegate to that instance.
  class Current
    SUPERCLASSES = %w[ActiveSupport::CurrentAttributes Spinrail::CurrentAttributes].freeze

    def self.current?(klass) = klass.superclass && SUPERCLASSES.include?(klass.superclass.slice)

    def initialize(file, rel, build)
      @file = rel
      @build = build
      source = File.read(file)
      @klass = Spinrail.parse(source, rel).statements.body.find { |n| n.is_a?(Prism::ClassNode) }
      @name = @klass.constant_path.slice
      @attributes = []
      @body = []
      @public = []
      private_section = false
      (@klass.body&.body || []).each do |stmt|
        if stmt.is_a?(Prism::CallNode) && stmt.receiver.nil? && stmt.name == :attribute
          args, kw = Spinrail.call_args(stmt)
          raise CompileError, "#{rel}:#{stmt.location.start_line}: attribute takes names only" if kw.any?
          @attributes.concat(args.map { |a| Spinrail.literal(a).to_s })
          next
        end
        if stmt.is_a?(Prism::CallNode) && stmt.receiver.nil? && %i[private protected].include?(stmt.name) && stmt.arguments.nil?
          private_section = true
        elsif stmt.is_a?(Prism::DefNode) && stmt.receiver.nil? && !private_section
          @public << stmt
        end
        @body << stmt.slice.gsub(/^ {#{stmt.location.start_column}}/, "")
      end
    end

    def to_ruby
      base = "#{@name}Attributes"
      ivars = @attributes.map { |a| "    @#{a} = nil" }
      body = Lowering.lower(@body.join("\n\n"), @file, Build::Context.new(@build, "", view: false))
      delegations = @attributes.flat_map { |a| [delegate(a, ""), delegate("#{a}=", "value")] }
      delegations += @public.map { |d| delegate(d.name.to_s, params(d)) }
      <<~RUBY
        class #{base}
        #{accessors.gsub(/^(?=.)/, '  ')}
          def initialize
        #{ivars.join("\n")}
          end
        end

        class #{@name} < #{base}
        #{body.gsub(/^(?=.)/, '  ')}

          def self.instance
            slot = Tep::APP.sched_current + 1
            INSTANCES.push(#{@name}.new) while INSTANCES.length <= slot
            INSTANCES[slot]
          end

          def self.reset
            instance
            INSTANCES[Tep::APP.sched_current + 1] = #{@name}.new
          end

        #{delegations.uniq.join("\n\n").gsub(/^(?=.)/, '  ')}
        end

        class #{@name}
          INSTANCES = [#{@name}.new]
        end

        module Spinrail
          def self.reset_current = #{@name}.reset
        end
      RUBY
    end

    private

    # Written out: spinel loses an inherited attr_accessor writer called
    # through an Array element here.
    def accessors
      @attributes.map { |a| "def #{a} = @#{a}\n\ndef #{a}=(value)\n  @#{a} = value\nend\n" }.join("\n")
    end

    def delegate(name, params)
      sig = params.empty? ? "" : "(#{params})"
      if name.end_with?("=")
        "def self.#{name}(#{params})\n  instance.#{name.delete_suffix('=')} = #{params}\nend"
      else
        "def self.#{name}#{sig}\n  instance.#{name}#{sig.empty? ? '' : "(#{args(params)})"}\nend"
      end
    end

    def params(defn)
      p = defn.parameters
      return "" unless p
      unless p.rest.nil? && p.posts.empty? && p.keyword_rest.nil? && p.block.nil?
        raise CompileError, "#{@file}:#{defn.location.start_line}: #{@name}.#{defn.name} takes only plain and keyword arguments"
      end
      p.slice
    end

    # "a, b = 1, c:, d: 2" -> "a, b, c: c, d: d"
    def args(params)
      Spinrail.parse("def x(#{params}); end", @file).statements.body.first.parameters.then do |p|
        (p.requireds + p.optionals).map { |n| n.name.to_s } + p.keywords.map { |k| "#{k.name}: #{k.name}" }
      end.join(", ")
    end
  end
end
