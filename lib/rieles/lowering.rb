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
                        rescue_from protect_from_forgery skip_forgery_protection layout].freeze

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
      @forms = []
    end

    FIELDS = {
      text_field: "text", email_field: "email", password_field: "password", number_field: "number",
      hidden_field: "hidden", date_field: "date", url_field: "url", search_field: "search",
      telephone_field: "tel", color_field: "color"
    }.freeze
    BUILDER = (FIELDS.keys + %i[label text_area textarea check_box checkbox select collection_select submit]).freeze

    def visit_call_node(node)
      if @ctx.view? && node.name == :form_with && node.receiver.nil? && node.block
        lower_form(node)
        super
        @forms.pop
        return
      end
      if i18n_call?(node)
        lower_i18n(node)
      elsif @ctx.controller? && node.receiver.nil? && node.name == :respond_to && node.block
        lower_respond_to(node)
      elsif @ctx.view? && node.receiver.nil? && %i[content_for provide content_for?].include?(node.name)
        lower_content_for(node)
      elsif @forms.any? && local?(node.receiver, @forms.last[:var]) && BUILDER.include?(node.name)
        lower_field(node)
      elsif @ctx.view? && node.receiver.nil? && node.name == :link_to && node.block
        lower_link_block(node)
      elsif @ctx.view? && node.receiver.nil? && node.name == :dom_id && node.arguments&.arguments&.size == 1
        arg = node.arguments.arguments.first
        @rw.replace(node) { "(#{@rw.slice(arg)}).dom_id" }
      elsif @ctx.view? && node.receiver.nil? && %i[link_to button_to].include?(node.name) && node.block.nil?
        lower_link(node)
      elsif params_call?(node)
        lower_params(node)
      elsif mass_assignment?(node)
        lower_mass_assignment(node)
      elsif query_call?(node)
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
      elsif @ctx.action? && local?(node.receiver, :response) && node.name == :status=
        arg = node.arguments.arguments.first
        @rw.replace(node) { "@res.set_status(#{arg.is_a?(Prism::SymbolNode) ? status_code(arg) : @rw.slice(arg)})" }
      elsif @ctx.action? && node.receiver.nil? && node.name == :halt
        lower_halt(node)
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

    def visit_yield_node(node)
      args = node.arguments&.arguments || []
      if @ctx.view? && args.size == 1 && args.first.is_a?(Prism::SymbolNode)
        @rw.replace(node) { "content_for_get(#{args.first.unescaped.inspect})" }
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
      when :includes, :preload, :eager_load then !node.receiver.nil?
      else false
      end
    end

    def params_call?(node)
      return false unless node.receiver
      case node.name
      when :require, :permit then true
      when :expect then bare?(node.receiver, :params)
      else false
      end
    end

    def lower_params(node)
      args, kw = Rieles.call_args(node)
      @rw.replace(node) do
        recv = @rw.slice(node.receiver)
        case node.name
        when :require then "#{recv}.require_key(#{Rieles.literal(args.first).to_s.inspect})"
        when :permit then "#{recv}.permit_keys(#{args.map { |a| Rieles.literal(a).to_s }.inspect})"
        when :expect
          key, fields = kw.first
          "#{recv}.require_key(#{key.to_s.inspect}).permit_keys(#{Rieles.literal(fields).map(&:to_s).inspect})"
        end
      end
    end

    MASS = { new: "from_params", create: "create_from", create!: "create_from!",
             update: "update_from", update!: "update_from!", assign_attributes: "assign_params" }.freeze

    # Model.new(entry_params) / record.update(entry_params): a Parameters
    # object instead of keywords.
    def mass_assignment?(node)
      return false unless MASS.key?(node.name) && node.receiver && node.block.nil?
      args = node.arguments&.arguments || []
      return true if relation_build?(node)
      return false unless args.size == 1 && !args.first.is_a?(Prism::KeywordHashNode) && !args.first.is_a?(Prism::HashNode)
      return @ctx.model?(node.receiver.slice) || association?(node.receiver) if %i[new create create!].include?(node.name)
      true
    end

    # post.comments.new(...) is a relation building a scoped record.
    def association?(recv) = recv.is_a?(Prism::CallNode) && recv.receiver && recv.arguments.nil?

    def relation_build?(node)
      node.name == :new && association?(node.receiver) &&
        (node.arguments.nil? || node.arguments.arguments.last.is_a?(Prism::KeywordHashNode))
    end

    def lower_mass_assignment(node)
      if relation_build?(node)
        @rw.replace(node) { "#{@rw.slice(node.receiver)}.build#{node.arguments ? "(#{@rw.slice(node.arguments)})" : ''}" }
        return
      end
      arg = node.arguments.arguments.first
      method = MASS[node.name]
      method = "build_from" if node.name == :new && association?(node.receiver)
      @rw.replace(node) { "#{@rw.slice(node.receiver)}.#{method}(#{@rw.slice(arg)})" }
    end

    # form_with(model: @entry) do |f| ... end, inlined: the block body
    # writes to the template's `out` between the form tags.
    def lower_form(node)
      args, kw = Rieles.call_args(node)
      fail!(node, "form_with takes keyword options") unless args.empty?
      var = node.block.parameters&.parameters&.requireds&.first&.name or fail!(node, "form_with needs a block parameter")
      model = kw[:model]
      parent = nil
      if model.is_a?(Prism::ArrayNode)
        fail!(node, "form_with model: [parent, record]") unless model.elements.size == 2
        parent, model = model.elements
      end
      scope = kw[:scope] ? Rieles.literal(kw[:scope]).to_s : model ? model_scope(model) : ""
      @forms << { var: var, scope: scope, model: model }
      attrs = html_attrs(kw.reject { |k, _| %i[model scope url method local].include?(k) })
      @rw.replace(node) do
        m = model && @rw.slice(model)
        url = if kw[:url] then @rw.slice(kw[:url])
              elsif parent then nested_model_url(node, model_scope(parent), @rw.slice(parent), scope, m)
              else model_url(node, scope, m)
              end
        method = if kw[:method] then Rieles.literal(kw[:method]).to_s.inspect
                 elsif m then "(#{m}.persisted? ? \"patch\" : \"post\")"
                 else '"post"'
                 end
        body = node.block.body ? @rw.slice(node.block.body) : ""
        "out << form_open(#{url}, #{method}, #{attrs})\n#{body}\nout << \"</form>\""
      end
    end

    def model_scope(model)
      name = model.slice.delete_prefix("@")
      fail!(model, "form_with model: expects @record or scope:") unless name.match?(/\A[a-z_]\w*\z/)
      name
    end

    def model_url(node, scope, model)
      plural = Inflector.pluralize(scope)
      member = "#{scope}_path"
      collection = "#{plural}_path"
      has_member = @ctx.path_helper?(member)
      has_collection = @ctx.path_helper?(collection)
      fail!(node, "form_with model: needs #{collection} or #{member}, or url:") unless has_member || has_collection
      return collection unless has_member
      return "#{member}(#{model})" unless has_collection
      "(#{model}.persisted? ? #{member}(#{model}) : #{collection})"
    end

    # [@post, @comment]: post_comments_path(post) to create, and
    # post_comment_path(post, comment) or a shallow comment_path(comment).
    def nested_model_url(node, parent_scope, parent, scope, model)
      collection = "#{parent_scope}_#{Inflector.pluralize(scope)}_path"
      fail!(node, "form_with needs #{collection}") unless @ctx.path_helper?(collection)
      member = if @ctx.path_helper?("#{parent_scope}_#{scope}_path") then "#{parent_scope}_#{scope}_path(#{parent}, #{model})"
               elsif @ctx.path_helper?("#{scope}_path") then "#{scope}_path(#{model})"
               end
      return "#{collection}(#{parent})" unless member
      "(#{model}.persisted? ? #{member} : #{collection}(#{parent}))"
    end

    def lower_field(node)
      form = @forms.last
      model = form[:model]
      attr_node = node.arguments&.arguments&.first
      if model && attr_node.is_a?(Prism::SymbolNode) && node.name != :submit
        return lower_field_html(node, form, ->(html) { "field_errors_wrap((#{@rw.slice(model)}).errors[#{attr_node.unescaped.inspect}].empty?, #{html})" })
      end
      lower_field_html(node, form, ->(html) { html })
    end

    def lower_field_html(node, form, wrap)
      args, kw = Rieles.call_args(node)
      attr = args.first && (args.first.is_a?(Prism::SymbolNode) || args.first.is_a?(Prism::StringNode)) ? args.first.unescaped : nil
      model = form[:model]
      @rw.replace(node) do
        wrap.call(field_html(node, form, args, kw, attr, model))
      end
    end

    def field_html(node, form, args, kw, attr, model)
      m = model && @rw.slice(model)
      value = ->(cast) { m && attr ? "(#{m}.#{attr})#{cast}" : (cast == "" ? "false" : '""') }
      attrs = html_attrs(kw)
      scope = form[:scope].inspect
      case node.name
      when :label
        text = args[1] ? @rw.slice(args[1]) : Inflector.humanize(attr.to_s).inspect
        "form_label(#{scope}, #{attr.inspect}, #{text}, #{attrs})"
      when :text_area, :textarea then "form_textarea(#{scope}, #{attr.inspect}, #{value.(".to_s")}, #{attrs})"
      when :check_box, :checkbox then "form_check_box(#{scope}, #{attr.inspect}, #{value.("")}, #{attrs})"
      when :select
        fail!(node, "f.select(:attr, choices)") unless args[1]
        "form_select(#{scope}, #{attr.inspect}, #{value.(".to_s")}, #{@rw.slice(args[1])}, #{attrs})"
      when :collection_select
        fail!(node, "f.collection_select(:attr, records, :value_method, :text_method)") unless args.size == 4
        coll = "(#{@rw.slice(args[1])}).to_a"
        v, t = Rieles.literal(args[2]), Rieles.literal(args[3])
        "form_select_pairs(#{scope}, #{attr.inspect}, #{value.(".to_s")}, #{coll}.map { |r| r.#{v}.to_s }, " \
          "#{coll}.map { |r| r.#{t}.to_s }, #{attrs})"
      when :submit
        text = if args.first then @rw.slice(args.first)
               elsif m then "(#{m}.persisted? ? \"Update #{Inflector.humanize(form[:scope])}\" : \"Create #{Inflector.humanize(form[:scope])}\")"
               else '"Submit"'
               end
        "form_submit(#{text}, #{attrs})"
      else
        v = node.name == :password_field ? '""' : value.(".to_s")
        "form_input(#{FIELDS.fetch(node.name).inspect}, #{scope}, #{attr.inspect}, #{v}, #{attrs})"
      end
    end

    def i18n_call?(node)
      i18n = node.receiver.is_a?(Prism::ConstantReadNode) && node.receiver.name == :I18n
      return %i[t translate locale locale=].include?(node.name) if i18n
      node.receiver.nil? && %i[t translate].include?(node.name) && node.arguments
    end

    # t("key"), t(".lazy") (scoped to the template, or controller.action),
    # t("key", name: value), I18n.locale and I18n.locale = "es".
    def lower_i18n(node)
      case node.name
      when :locale then return @rw.replace(node) { "Rieles.locale" }
      when :locale= then return @rw.replace(node) { "Rieles.set_locale((#{@rw.slice(node.arguments.arguments.first)}).to_s)" }
      end
      args, kw = Rieles.call_args(node)
      key_node = args.first or fail!(node, "t needs a key")
      literal = key_node.is_a?(Prism::StringNode) || key_node.is_a?(Prism::SymbolNode)
      static = literal && (key_node.unescaped.start_with?(".") ? "#{lazy_scope(node)}#{key_node.unescaped}" : key_node.unescaped)
      @rw.replace(node) do
        key = static ? static.inspect : "(#{@rw.slice(key_node)}).to_s"
        if kw.empty?
          "Rieles.t(#{key})"
        else
          "Rieles.t_with(#{key}, #{kw.keys.map(&:to_s).inspect}, [#{kw.values.map { |v| "(#{@rw.slice(v)}).to_s" }.join(', ')}])"
        end
      end
    end

    def lazy_scope(node)
      return @ctx.i18n_scope if @ctx.i18n_scope
      return "#{@ctx.dir.tr('/', '.')}.#{@ctx.current_def}" if @ctx.controller? && @ctx.current_def
      fail!(node, "lazy lookup t(\".key\") only works in templates and controller actions")
    end

    # respond_to do |format| format.html { } format.json { } end -> if/else
    # on the request's format (Accept header or ?format=).
    def lower_respond_to(node)
      var = node.block.parameters&.parameters&.requireds&.first&.name or fail!(node, "respond_to needs |format|")
      branches = (node.block.body&.body || []).map do |stmt|
        unless stmt.is_a?(Prism::CallNode) && local?(stmt.receiver, var) && %i[html json].include?(stmt.name)
          fail!(stmt, "respond_to supports format.html and format.json")
        end
        [stmt.name, stmt.block&.body]
      end
      @rw.replace(node) do
        code = branches.map.with_index do |(format, body), i|
          test = format == :json ? "wants_json?" : "!wants_json?"
          "#{i.zero? ? 'if' : 'elsif'} #{test}\n#{body ? @rw.slice(body) : 'nil'}"
        end
        code.join("\n") + "\nelse\nhead(406)\nend"
      end
    end

    # Stored on the controller: the page and its layout are rendered by
    # different view instances. The block form captures what it writes.
    def lower_content_for(node)
      args, = Rieles.call_args(node)
      key = Rieles.literal(args.first).to_s.inspect
      @rw.replace(node) do
        if node.name == :content_for?
          "content_for?(#{key})"
        elsif node.block
          body = node.block.body ? @rw.slice(node.block.body) : ""
          "rieles_outer = out\nout = +\"\"\n#{body}\ncontent_for_set(#{key}, out)\nout = rieles_outer"
        elsif args[1]
          "content_for_set(#{key}, (#{@rw.slice(args[1])}).to_s)"
        else
          "content_for_get(#{key}).to_s"
        end
      end
    end

    # <%= link_to path, class: "x" do %>...<% end %>, inlined like form_with.
    def lower_link_block(node)
      args, kw = Rieles.call_args(node)
      fail!(node, "link_to with a block takes the url") unless args.size == 1
      @rw.replace(node) do
        open = "\"<a href=\\\"\" + h((#{@rw.slice(args[0])}).to_s) + \"\\\"\" + #{html_attrs(kw)} + \">\""
        body = node.block.body ? @rw.slice(node.block.body) : ""
        "out << #{open}\n#{body}\nout << \"</a>\""
      end
    end

    def lower_link(node)
      args, kw = Rieles.call_args(node)
      fail!(node, "#{node.name}(text, url, html_options)") unless args.size == 2
      method = kw[:method] ? Rieles.literal(kw[:method]).to_s : "post"
      @rw.replace(node) do
        attrs = html_attrs(kw.reject { |k, _| k == :method })
        text = "(#{@rw.slice(args[0])}).to_s"
        url = "(#{@rw.slice(args[1])}).to_s"
        node.name == :link_to ? "link_to(#{text}, #{url}, #{attrs})" : "button_to(#{text}, #{url}, #{method.inspect}, #{attrs})"
      end
    end

    # class: "btn", required: true, data: { confirm: "?" } -> ' class="btn" required data-confirm="?"'
    def html_attrs(kw)
      parts = kw.flat_map do |key, value|
        if key == :data && value.is_a?(Prism::HashNode)
          value.elements.map { |a| attr_part("data-#{Rieles.literal(a.key).to_s.tr('_', '-')}", a.value) }
        else
          [attr_part(key.to_s.tr("_", "-"), value)]
        end
      end.compact
      parts.empty? ? '""' : parts.join(" + ")
    end

    def attr_part(name, value)
      case value
      when Prism::TrueNode then " #{name}".inspect
      when Prism::FalseNode, Prism::NilNode then nil
      when Prism::StringNode, Prism::IntegerNode, Prism::SymbolNode
        %( #{name}="#{CGI.escapeHTML(Rieles.literal(value).to_s)}").inspect
      else "#{%( #{name}=").inspect} + h((#{@rw.slice(value)}).to_s) + #{'"'.inspect}"
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
      # cookies.signed / cookies.permanent / cookies.permanent.signed
      if %i[signed permanent].include?(recv.name)
        chain = [recv.name]
        base = recv.receiver
        if base.is_a?(Prism::CallNode) && base.name == :permanent && base.arguments.nil?
          chain.unshift(:permanent)
          base = base.receiver
        end
        return nil unless bare?(base, :cookies)
        kind = chain.join("_")
        return [:cookie, node.name == :[]= ? :"set_#{kind}" : :"get_#{kind}"] if %i[[] []=].include?(node.name)
      end
      return nil unless recv.receiver.nil? && %i[session flash cookies].include?(recv.name)
      store = recv.name == :cookies ? :cookie : recv.name
      case node.name
      when :[] then [store, :get]
      when :[]= then [store, :set]
      when :delete then recv.name == :flash ? nil : [store, :delete]
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
        when :get_signed then "cookie_get_signed(#{k})"
        when :set_signed, :set_permanent, :set_permanent_signed then "#{store}_#{op}(#{k}, #{@rw.slice(value)})"
        else fail!(node, "unsupported cookies access")
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
        when :includes, :preload, :eager_load
          names = node.arguments.arguments.map { |a| Rieles.literal(a).to_s }
          "#{prefix.call}with_includes(#{names.inspect})"
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
        "render_view(ApplicationView.new(self).#{view.method_name}(#{values.join(', ')}), @res.status)"
      end
    end

    # halt 401 / halt 422, "body": respond and leave the method.
    def lower_halt(node)
      args, = Rieles.call_args(node)
      fail!(node, "halt takes a status and an optional body") unless (1..2).cover?(args.size)
      code = status_code(args[0])
      @ctx.record_response(nil, where(node))
      @rw.replace(node) do
        body = args[1] ? "(#{@rw.slice(args[1])}).to_s" : "Tep.reason(#{code})"
        "return render_plain(#{body}, #{code})"
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
        layout = ""
        if kw.key?(:layout)
          value = Rieles.literal(kw[:layout])
          layout = value ? value.to_s : "none"
          fail!(node, "no app/views/layouts/#{layout}.html.erb") if value && !@ctx.layout?(layout)
        end
        @rw.replace(node) { layout.empty? ? "#{method}(#{status})" : "#{method}(#{status}, #{layout.inspect})" }
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
      if args.size == 1 && !args.first.is_a?(Prism::StringNode)
        return lower_record_partial(node, args.first)
      end
      if kw[:partial] && kw[:collection]
        name = Rieles.literal(kw[:partial]).to_s
        return lower_collection(node, name, kw[:collection], kw[:as] ? Rieles.literal(kw[:as]).to_s : File.basename(name))
      end
      fail!(node, "render in views takes a partial name: render \"name\", local: value") unless args.size == 1
      name = Rieles.literal(args.first).to_s
      dir, base = name.include?("/") ? [File.dirname(name), File.basename(name)] : [@ctx.dir, name]
      method, keywords = @ctx.partial_method("#{dir}/_#{base}", kw.keys, "#{@file}:#{node.location.start_line}")
      @rw.replace(node) do
        args = kw.map { |k, v| keywords ? "#{k}: #{@rw.slice(v)}" : @rw.slice(v) }
        "#{method}(#{args.join(', ')})"
      end
    end

    # render @entries / render entry: the partial is named after the
    # variable, entries/_entry.html.erb with local `entry`.
    def lower_record_partial(node, value)
      name = value.slice.delete_prefix("@")
      fail!(node, "render @records needs a variable, got `#{value.slice}`") unless name.match?(/\A[a-z_]\w*\z/)
      single = Inflector.singularize(name)
      if single == name
        method, keywords = @ctx.partial_method("#{Inflector.pluralize(name)}/_#{name}", [name.to_sym], where(node))
        @rw.replace(node) { "#{method}(#{keywords ? "#{name}: " : ''}#{@rw.slice(value)})" }
      else
        lower_collection(node, "#{name}/#{single}", value, single)
      end
    end

    def lower_collection(node, name, collection, local)
      dir, base = name.include?("/") ? [File.dirname(name), File.basename(name)] : [@ctx.dir, name]
      method, keywords = @ctx.partial_method("#{dir}/_#{base}", [local.to_sym], where(node))
      @rw.replace(node) { "(#{@rw.slice(collection)}).to_a.map { |#{local}| #{method}(#{keywords ? "#{local}: " : ''}#{local}) }.join" }
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
