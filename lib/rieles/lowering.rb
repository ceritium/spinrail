module Rieles
  # Applies replacements to Prism node ranges. Replacements are lazy so they
  # can embed the (rewritten) source of their own child nodes.
  class SourceRewriter
    Edit = Struct.new(:start, :stop, :fn)

    def initialize(source)
      @source = source.b
      @edits = []
      @active = []
    end

    def replace(node, &fn)
      @edits << Edit.new(node.location.start_offset, node.location.end_offset, fn)
    end

    def slice(node)
      emit(node.location.start_offset, node.location.end_offset)
    end

    def emit(start = 0, stop = @source.bytesize)
      out = +""
      pos = start
      # An edit slicing its own node must see the original source, not itself.
      inside = @edits.select { |e| e.start >= start && e.stop <= stop && !@active.include?(e) }
      inside.sort_by { |e| [e.start, -e.stop] }.each do |e|
        next if e.start < pos
        out << @source.byteslice(pos, e.start - pos)
        @active.push(e)
        out << e.fn.call.b
        @active.pop
        pos = e.stop
      end
      out << @source.byteslice(pos, stop - pos)
      out.force_encoding("UTF-8")
    end
  end

  # Rewrites Rails idioms that need runtime metaprogramming into plain calls:
  # params[:x], render, redirect_to. In templates, @ivar reads become the
  # template's exposures (explicit parameters); in controllers, ivar writes
  # and renders are recorded per action so the build can check them.
  class Lowering < Prism::Visitor
    STATUS = {
      ok: 200, created: 201, no_content: 204, moved_permanently: 301, found: 302,
      see_other: 303, bad_request: 400, unauthorized: 401, forbidden: 403,
      not_found: 404, unprocessable_entity: 422, unprocessable_content: 422,
      internal_server_error: 500
    }.freeze

    # Class-level controller declarations; the build reads them, the
    # generated class doesn't need them.
    CONTROLLER_DSL = %i[before_action after_action skip_before_action skip_after_action
                        rescue_from protect_from_forgery skip_forgery_protection].freeze

    def self.lower(source, file, context)
      root = Rieles.parse(source, file)
      rewriter = SourceRewriter.new(source)
      root.accept(new(rewriter, file, context))
      rewriter.emit
    end

    def initialize(rewriter, file, context)
      @rw = rewriter
      @file = file
      @ctx = context
    end

    def visit_call_node(node)
      if query_call?(node)
        lower_query(node)
      elsif (store = store_access(node))
        lower_store(node, *store)
      elsif params_lookup?(node)
        key = Rieles.literal(node.arguments.arguments.first).to_s
        @rw.replace(node) { "param(#{key.inspect})" }
      elsif @ctx.action? && local?(node.receiver, :response) && node.name == :render
        lower_action_render(node)
      elsif @ctx.action? && local?(node.receiver, :response) && node.name == :redirect_to
        lower_redirect(node)
      elsif node.receiver.nil? && @ctx.controller? && CONTROLLER_DSL.include?(node.name)
        @rw.replace(node) { "" }
      elsif node.receiver.nil? && node.block.nil?
        case node.name
        when :render then lower_render(node)
        when :redirect_to then lower_redirect(node)
        when :head then lower_head(node)
        end
      end
      super
    end

    def visit_def_node(node)
      @ctx.enter_def(node.name.to_s)
      super
    end

    def visit_instance_variable_read_node(node)
      if @ctx.view?
        name = node.name.to_s.delete_prefix("@")
        @ctx.expose(name, where(node))
        @rw.replace(node) { "iv_#{name}" }
      end
      super
    end

    def visit_instance_variable_write_node(node)
      record_ivar_write(node)
      super
    end

    def visit_instance_variable_or_write_node(node)
      record_ivar_write(node)
      super
    end

    def visit_instance_variable_operator_write_node(node)
      record_ivar_write(node)
      super
    end

    private

    def where(node) = "#{@file}:#{node.location.start_line}"

    # Query forms whose argument types differ from the common case get
    # their own method: where.not(...), pluck(:col), order("sql"), exists?(...).
    def query_call?(node)
      args = node.arguments&.arguments || []
      case node.name
      when :not then node.receiver.is_a?(Prism::CallNode) && node.receiver.name == :where && node.receiver.arguments.nil?
      when :pluck then args.size == 1 && args.first.is_a?(Prism::SymbolNode)
      when :order then args.size == 1 && args.first.is_a?(Prism::StringNode)
      when :exists? then args.size == 1
      else false
      end
    end

    # session[:k], session[:k] = v, session.delete(:k), flash[:k],
    # flash[:k] = v, flash.now[:k] = v: Tep's session is a String store.
    def store_access(node)
      recv = node.receiver
      return nil unless recv.is_a?(Prism::CallNode) && recv.arguments.nil?
      if recv.name == :now && bare?(recv.receiver, :flash) && node.name == :[]=
        return [:flash_now, :set]
      end
      return nil unless recv.receiver.nil? && %i[session flash].include?(recv.name)
      case node.name
      when :[] then [recv.name, :get]
      when :[]= then [recv.name, :set]
      when :delete then recv.name == :session ? [:session, :delete] : nil
      end
    end

    def bare?(node, name) = node.is_a?(Prism::CallNode) && node.receiver.nil? && node.name == name && node.arguments.nil?

    def lower_store(node, store, op)
      key, value = node.arguments.arguments
      @rw.replace(node) do
        k = key.is_a?(Prism::SymbolNode) || key.is_a?(Prism::StringNode) ? key.unescaped.inspect : "(#{@rw.slice(key)}).to_s"
        case op
        when :get then "#{store}_get(#{k})"
        when :set then "#{store}_set(#{k}, #{@rw.slice(value)})"
        when :delete then "#{store}_delete(#{k})"
        end
      end
    end

    def lower_query(node)
      recv = node.name == :not ? node.receiver.receiver : node.receiver
      prefix = -> { recv ? "#{@rw.slice(recv)}." : "" }
      arg = node.arguments.arguments.first
      @rw.replace(node) do
        case node.name
        when :not then "#{prefix.call}where_not(#{@rw.slice(arg)})"
        when :pluck then "#{prefix.call}pluck_#{arg.unescaped}"
        when :order then "#{prefix.call}order_sql(#{@rw.slice(arg)})"
        when :exists? then "#{prefix.call}where(#{@rw.slice(arg)}).exists?"
        end
      end
    end

    def record_ivar_write(node)
      fail!(node, "templates can't assign instance variables") if @ctx.view?
      @ctx.assign(node.name.to_s.delete_prefix("@"))
    end

    def params_lookup?(node)
      return false unless node.name == :[] && node.arguments&.arguments&.size == 1
      recv = node.receiver
      return false unless recv.is_a?(Prism::CallNode) && recv.name == :params && recv.arguments.nil?
      recv.receiver.nil? || local?(recv.receiver, :request)
    end

    def local?(node, name)
      node.is_a?(Prism::LocalVariableReadNode) && node.name == name
    end

    # Action classes: response.render(view, name: value, ...) passes the
    # view's exposures by name; the build checks them against `expose`.
    def lower_action_render(node)
      args, kw = Rieles.call_args(node)
      unless args.size == 1 && args.first.is_a?(Prism::CallNode) && args.first.name == :view
        fail!(node, "expected response.render(view, exposure: value, ...)")
      end
      view = @ctx.action_view(kw.keys, where(node))
      @ctx.record_response(nil, where(node))
      @rw.replace(node) do
        values = view.exposures.map { |e| @rw.slice(kw.fetch(e.to_sym)) }
        "render_view(ApplicationView.new(self).#{view.method_name}(#{values.join(', ')}), 200)"
      end
    end

    def lower_redirect(node)
      args, kw = Rieles.call_args(node)
      fail!(node, "redirect_to needs a location") if args.empty?
      status = kw[:status] ? status_code(kw[:status]) : 302
      @ctx.record_response(nil, where(node))
      unknown = kw.keys - %i[status notice alert]
      fail!(node, "unsupported redirect_to option #{unknown.first}") if unknown.any?
      if kw[:notice] || kw[:alert]
        @rw.replace(node) do
          n = kw[:notice] ? @rw.slice(kw[:notice]) : '""'
          a = kw[:alert] ? @rw.slice(kw[:alert]) : '""'
          "redirect_with_flash(#{@rw.slice(args.first)}, #{status}, #{n}, #{a})"
        end
      else
        @rw.replace(node) { "redirect_to(#{@rw.slice(args.first)}, #{status})" }
      end
    end

    def lower_render(node)
      args, kw = Rieles.call_args(node)
      @ctx.view? ? lower_partial(node, args, kw) : lower_template(node, args, kw)
    end

    def lower_template(node, args, kw)
      status = kw[:status] ? status_code(kw[:status]) : 200
      if kw[:view]
        # render view: Views::Stats::Show, count: ... -- a Hanami-style view from a controller.
        exposures = kw.reject { |k, _| %i[view status].include?(k) }
        key = Rieles.class_key(kw[:view].slice, "Views") or fail!(node, "expected view: Views::..., got `#{kw[:view].slice}`")
        view = @ctx.view_for(key, exposures.keys, where(node))
        @ctx.record_response(nil, where(node))
        @rw.replace(node) do
          values = view.exposures.map { |e| @rw.slice(exposures.fetch(e.to_sym)) }
          "render_view(ApplicationView.new(self).#{view.method_name}(#{values.join(', ')}), #{status})"
        end
      elsif kw[:json]
        @ctx.record_response(nil, where(node))
        @rw.replace(node) { "render_json(#{json(kw[:json])}, #{status})" }
      elsif kw[:plain]
        @ctx.record_response(nil, where(node))
        @rw.replace(node) { "render_plain(#{@rw.slice(kw[:plain])}, #{status})" }
      elsif args.first
        name = Rieles.literal(args.first).to_s
        template = name.include?("/") ? name : "#{@ctx.dir}/#{name}"
        method = @ctx.render_method(template) or fail!(node, "missing template app/views/#{template}.html.erb")
        @ctx.record_response(template, where(node))
        @rw.replace(node) { "#{method}(#{status})" }
      else
        fail!(node, "unsupported render: `#{node.slice}`")
      end
    end

    def lower_head(node)
      args, = Rieles.call_args(node)
      fail!(node, "head takes a status") unless args.size == 1
      @ctx.record_response(nil, where(node))
      code = status_code(args.first)
      @rw.replace(node) { "head(#{code})" }
    end

    # Hash and array literals are encoded at build time; anything else
    # answers to_json (models, relations, core values; see the runtime).
    def json(node)
      case node
      when Prism::HashNode, Prism::KeywordHashNode
        pairs = node.elements.map do |a|
          fail!(a, "JSON keys must be symbols or strings") unless a.key.is_a?(Prism::SymbolNode) || a.key.is_a?(Prism::StringNode)
          "#{"#{a.key.unescaped.to_json}:".inspect} + #{json(a.value)}"
        end
        pairs.empty? ? '"{}"' : "\"{\" + #{pairs.join(' + "," + ')} + \"}\""
      when Prism::ArrayNode
        items = node.elements.map { |e| json(e) }
        items.empty? ? '"[]"' : "\"[\" + #{items.join(' + "," + ')} + \"]\""
      else "(#{@rw.slice(node)}).to_json"
      end
    end

    def lower_partial(node, args, kw)
      fail!(node, "render in views takes a partial name: render \"name\", local: value") unless args.size == 1
      name = Rieles.literal(args.first).to_s
      dir, base = name.include?("/") ? [File.dirname(name), File.basename(name)] : [@ctx.dir, name]
      method = @ctx.partial_method("#{dir}/_#{base}", kw.keys, "#{@file}:#{node.location.start_line}")
      @rw.replace(node) { "#{method}(#{kw.values.map { |v| @rw.slice(v) }.join(', ')})" }
    end

    def status_code(node)
      value = Rieles.literal(node)
      return value if value.is_a?(Integer)
      STATUS.fetch(value) { fail!(node, "unknown status :#{value}") }
    end

    def fail!(node, message)
      raise CompileError, "#{@file}:#{node.location.start_line}: #{message}"
    end
  end
end
