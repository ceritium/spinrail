module Spinrail
  # class Current < ActiveSupport::CurrentAttributes: one instance per
  # fiber slot (Rails isolates per thread or fiber), reset around each
  # request and before each job and model test. Class methods delegate to
  # that instance.
  class Current
    SUPERCLASSES = %w[ActiveSupport::CurrentAttributes Spinrail::CurrentAttributes].freeze
    RESET_CALLBACKS = { before_reset: :before, after_reset: :after, resets: :after }.freeze

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
      @delegated = []
      @callbacks = { before: [], after: [] }
      private_section = false
      (@klass.body&.body || []).each do |stmt|
        call = stmt.is_a?(Prism::CallNode) && stmt.receiver.nil? ? stmt.name : nil
        if call == :attribute
          args, kw = Spinrail.call_args(stmt)
          raise CompileError, "#{where(stmt)}: attribute takes names only" if kw.any?
          @attributes.concat(args.map { |a| Spinrail.literal(a).to_s })
          next
        elsif RESET_CALLBACKS.key?(call)
          @callbacks[RESET_CALLBACKS[call]] << reset_callback(stmt)
          next
        end
        if call && %i[private protected].include?(call) && stmt.arguments.nil?
          private_section = true
        elsif stmt.is_a?(Prism::DefNode) && stmt.receiver.nil? && !private_section
          @public << stmt
        elsif Delegation.delegate?(stmt) && !private_section
          @delegated.concat(Delegation.expand(stmt, rel).first)
        end
        @body << stmt.slice.gsub(/^ {#{stmt.location.start_column}}/, "")
      end
    end

    def to_ruby
      base = "#{@name}Attributes"
      ivars = @attributes.map { |a| "    @#{a} = nil" }
      hooks = @callbacks.map { |kind, calls| "def spinrail_#{kind}_reset\n#{calls.join("\n").gsub(/^(?=.)/, '  ')}\nend" }
      body = Lowering.lower((@body + hooks).join("\n\n"), @file, Build::Context.new(@build, "", view: false))
      delegations = @attributes.flat_map { |a| [delegate(a, ""), delegate("#{a}=", "value")] }
      delegations += @public.map { |d| delegate(d.name.to_s, params(d)) }
      delegations += @delegated.map { |name, params| delegate(name, params) }
      <<~RUBY
        class #{base}
        #{accessors.gsub(/^(?=.)/, '  ')}
          def initialize
        #{ivars.join("\n")}
          end

          def spinrail_restore(other)
        #{@attributes.map { |a| "    @#{a} = other.spinrail_#{a}" }.join("\n")}
          end

        #{@attributes.map { |a| "  def spinrail_#{a} = @#{a}" }.join("\n")}
        end

        class #{@name} < #{base}
        #{body.gsub(/^(?=.)/, '  ')}

          def self.instance
            slot = Tep::APP.sched_current + 1
            INSTANCES.push(#{@name}.new) while INSTANCES.length <= slot
            INSTANCES[slot]
          end

          def self.reset
            instance.spinrail_before_reset
            fresh = #{@name}.new
            INSTANCES[Tep::APP.sched_current + 1] = fresh
            fresh.spinrail_after_reset
          end

          # Values given and not nil are set (through the writers) for the
          # block; every attribute is restored after it.
          def self.set(#{@attributes.map { |a| "#{a}: nil" }.join(', ')})
            current = instance
            saved = #{@name}.new
            saved.spinrail_restore(current)
        #{@attributes.map { |a| "    current.#{a} = #{a} unless #{a}.nil?" }.join("\n")}
            begin
              yield
            ensure
              current.spinrail_restore(saved)
            end
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

    def where(node) = "#{@file}:#{node.location.start_line}"

    # before_reset :m, resets { ... }: the body runs on the instance.
    def reset_callback(node)
      args, kw = Spinrail.call_args(node)
      raise CompileError, "#{where(node)}: #{node.name} takes no options" if kw.any?
      if node.block.is_a?(Prism::BlockNode) && args.empty?
        body = node.block.body
        return body ? body.slice.gsub(/^ {#{body.location.start_column}}/, "") : ""
      end
      raise CompileError, "#{where(node)}: #{node.name} takes method names or a block" if args.empty? || node.block
      args.map { |a| Spinrail.literal(a).to_s }.join("\n")
    end

    # Written out: spinel loses an inherited attr_accessor writer called
    # through an Array element here (ceritium/spinrail#1).
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
