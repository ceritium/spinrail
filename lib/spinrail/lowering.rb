module Spinrail
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
                        rescue_from protect_from_forgery skip_forgery_protection layout
                        http_basic_authenticate_with].freeze

    def self.lower(source, file, context)
      root = Spinrail.parse(source, file)
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
    BUILDER = (FIELDS.keys + %i[label text_area textarea check_box checkbox select collection_select file_field submit]).freeze

    def visit_call_node(node)
      check_n_plus_one(node)
      if @ctx.test? && node.receiver.nil? && lower_test_call(node)
        super
        return
      end
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
      elsif @ctx.view? && node.receiver.nil? && node.name == :turbo_frame_tag
        lower_turbo_frame(node)
      elsif @ctx.view? && node.receiver.nil? && node.name == :paginate && node.arguments&.arguments&.size == 1
        arg = node.arguments.arguments.first
        @rw.replace(node) { "pagination_links((#{@rw.slice(arg)}).current_page, (#{@rw.slice(arg)}).total_pages)" }
      elsif @ctx.view? && node.receiver.nil? && node.name == :dom_id && node.arguments&.arguments&.size == 1
        arg = node.arguments.arguments.first
        @rw.replace(node) { "(#{@rw.slice(arg)}).dom_id" }
      elsif @ctx.view? && node.receiver.nil? && %i[stylesheet_link_tag javascript_include_tag image_tag].include?(node.name)
        args, kw = Spinrail.call_args(node)
        @rw.replace(node) { "#{node.name}((#{@rw.slice(args.first)}).to_s, #{html_attrs(kw)})" }
      elsif @ctx.view? && node.receiver.nil? && %i[link_to button_to].include?(node.name) && node.block.nil?
        lower_link(node)
      elsif @ctx.action? && node.receiver.nil? && node.name == :params && node.block
        @rw.replace(node) { "" }
      elsif %i[valid? errors].include?(node.name) && request_params?(node.receiver)
        @rw.replace(node) { node.name == :valid? ? "params_valid?" : "params_errors" }
      elsif node.name == :params && (local?(node.receiver, :request) || bare?(node.receiver, :request)) && node.arguments.nil?
        @rw.replace(node) { "params" }
      elsif params_call?(node)
        lower_params(node)
      elsif mass_assignment?(node)
        lower_mass_assignment(node)
      elsif query_call?(node)
        lower_query(node)
      elsif (store = store_access(node))
        lower_store(node, *store)
      elsif params_lookup?(node)
        key = Spinrail.literal(node.arguments.arguments.first).to_s
        @rw.replace(node) { "param(#{key.inspect})" }
      elsif (path = nested_params_path(node))
        @rw.replace(node) { "param(#{(path.first + path.drop(1).map { |k| "[#{k}]" }.join).inspect})" }
      elsif @ctx.action? && local?(node.receiver, :response) && node.name == :render
        lower_action_render(node)
      elsif @ctx.action? && local?(node.receiver, :response) && node.name == :redirect_to
        lower_redirect(node)
      elsif @ctx.action? && local?(node.receiver, :response) && node.name == :status=
        arg = node.arguments.arguments.first
        @rw.replace(node) { "@res.set_status(#{arg.is_a?(Prism::SymbolNode) ? status_code(arg) : @rw.slice(arg)})" }
      elsif @ctx.action? && node.receiver.nil? && node.name == :halt
        lower_halt(node)
      elsif rails_cache_call?(node)
        lower_rails_cache(node)
      elsif @ctx.view? && node.receiver.nil? && node.name == :cache && node.block
        lower_fragment_cache(node)
      elsif @ctx.mailer? && node.receiver.nil? && node.name == :mail
        lower_mail(node)
      elsif @ctx.mailer? && node.receiver.nil? && %i[default layout].include?(node.name)
        @rw.replace(node) { "" }
      elsif mailer_call?(node)
        @rw.replace(node) { "#{node.receiver.slice}.new.#{node.name}#{node.arguments ? "(#{@rw.slice(node.arguments)})" : ''}" }
      elsif turbo_stream_call?(node)
        lower_turbo_stream(node)
      elsif job_call?(node)
        arg = node.arguments&.arguments&.first
        value = arg ? "(#{@rw.slice(arg)}).to_s" : '""'
        name = node.receiver.slice
        @rw.replace(node) { node.name == :perform_later ? "Spinrail.enqueue(#{name.inspect}, #{value})" : "#{name}.new.perform(#{value})" }
      elsif node.receiver.nil? && @ctx.job? && %i[queue_as retry_on discard_on].include?(node.name)
        @rw.replace(node) { "" }
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
      when :order then (args.size == 1 && args.first.is_a?(Prism::StringNode)) || (args.any? && args.all? { |a| a.is_a?(Prism::SymbolNode) })
      when :exists? then args.size == 1
      when :includes, :preload, :eager_load then !node.receiver.nil?
      when :joins, :left_joins, :left_outer_joins then args.any? && args.all? { |a| a.is_a?(Prism::SymbolNode) }
      when :where then args.size == 1 && args.first.is_a?(Prism::KeywordHashNode) && args.first.elements.any? { |e| e.value.is_a?(Prism::HashNode) }
      when :count then node.receiver.is_a?(Prism::CallNode) && node.receiver.name == :group && args.empty?
      else false
      end
    end

    # where(published: true, authors: { name: x }): plain pairs stay a hash,
    # table: { column: value } pairs become where_qualified("table.column", v).
    def lower_nested_where(prefix, hash)
      plain = hash.elements.reject { |e| e.value.is_a?(Prism::HashNode) }
      code = prefix + (plain.empty? ? "all" : "where(#{plain.map { |e| @rw.slice(e) }.join(', ')})")
      hash.elements.select { |e| e.value.is_a?(Prism::HashNode) }.each do |e|
        table = Spinrail.literal(e.key).to_s
        e.value.elements.each do |inner|
          code += ".where_qualified(#{"#{table}.#{Spinrail.literal(inner.key)}".inspect}, (#{@rw.slice(inner.value)}).to_s)"
        end
      end
      code
    end

    # posts.each { |post| post.comments } without includes(:comments)
    # queries once per post. A heuristic: the block variable's name gives
    # the model.
    def check_n_plus_one(node)
      return unless %i[each map each_with_index].include?(node.name) && node.receiver && node.block
      var = node.block.parameters&.parameters&.requireds&.first
      return unless var.respond_to?(:name)
      assocs = @ctx.associations_of(Inflector.camelize(var.name.to_s))
      return if assocs.empty?
      preloaded = node.receiver.slice
      find = lambda do |n|
        if n.is_a?(Prism::CallNode) && local?(n.receiver, var.name) && assocs.include?(n.name.to_s) &&
           !preloaded.match?(/\b(includes|preload|eager_load)\b[^.]*\b#{n.name}\b/)
          @ctx.warn("#{where(n)}: #{var.name}.#{n.name} inside a loop queries once per #{var.name}; " \
                    "add includes(:#{n.name}) to the collection")
        end
        n.compact_child_nodes.each { |c| find.call(c) }
      end
      find.call(node.block)
    end

    ASSERTIONS = %i[assert refute assert_not assert_equal assert_not_equal refute_equal assert_nil refute_nil assert_not_nil
                    assert_includes refute_includes assert_empty refute_empty assert_raises assert_difference
                    assert_no_difference fixtures].freeze

    # Minitest assertions become spinrail_assert(ok, "file:line", message);
    # posts(:first) becomes Post.find(<fixture id>).
    def lower_test_call(node)
      if @ctx.fixture_tables.include?(node.name.to_s) && node.arguments&.arguments&.size == 1
        label = Spinrail.literal(node.arguments.arguments.first).to_s
        model = Inflector.camelize(Inflector.singularize(node.name.to_s))
        id = Zlib.crc32(label) % (2**30 - 1)
        @rw.replace(node) { "#{model}.find(#{id})" }
        return true
      end
      return false unless ASSERTIONS.include?(node.name)
      args, = Spinrail.call_args(node)
      at = where(node).inspect
      s = ->(n) { "(#{@rw.slice(n)})" }
      @rw.replace(node) do
        case node.name
        when :fixtures then ""
        when :assert then "spinrail_assert(#{s.(args[0])}, #{at}, #{args[1] ? s.(args[1]) : '"Expected a truthy value"'})"
        when :refute, :assert_not then "spinrail_assert(!#{s.(args[0])}, #{at}, #{args[1] ? s.(args[1]) : '"Expected a falsy value"'})"
        when :assert_equal
          "spinrail_assert(#{s.(args[0])} == #{s.(args[1])}, #{at}, \"Expected \" + #{s.(args[0])}.inspect + \", got \" + #{s.(args[1])}.inspect)"
        when :assert_not_equal, :refute_equal
          "spinrail_assert(#{s.(args[0])} != #{s.(args[1])}, #{at}, \"Expected something other than \" + #{s.(args[0])}.inspect)"
        when :assert_nil then "spinrail_assert(#{s.(args[0])}.nil?, #{at}, \"Expected nil, got \" + #{s.(args[0])}.inspect)"
        when :refute_nil, :assert_not_nil then "spinrail_assert(!#{s.(args[0])}.nil?, #{at}, \"Expected a value, got nil\")"
        when :assert_includes
          "spinrail_assert(#{s.(args[0])}.include?(#{s.(args[1])}), #{at}, \"Expected \" + #{s.(args[0])}.inspect + \" to include \" + #{s.(args[1])}.inspect)"
        when :refute_includes
          "spinrail_assert(!#{s.(args[0])}.include?(#{s.(args[1])}), #{at}, #{s.(args[0])}.inspect + \" includes \" + #{s.(args[1])}.inspect)"
        when :assert_empty then "spinrail_assert(#{s.(args[0])}.empty?, #{at}, \"Expected empty, got \" + #{s.(args[0])}.inspect)"
        when :refute_empty then "spinrail_assert(!#{s.(args[0])}.empty?, #{at}, \"Expected not empty\")"
        when :assert_raises
          body = node.block&.body ? @rw.slice(node.block.body) : ""
          klass = args[0] ? @rw.slice(args[0]) : "StandardError"
          "begin\n#{body}\nflunk(#{at} + \": expected #{klass} to be raised\")\nrescue #{klass}\nnil\nend"
        when :assert_difference, :assert_no_difference
          expr = Spinrail.literal(args[0]).to_s
          diff = node.name == :assert_no_difference ? 0 : (args[1] ? Spinrail.literal(args[1]) : 1)
          body = node.block&.body ? @rw.slice(node.block.body) : ""
          "spinrail_before = (#{expr})\n#{body}\nspinrail_change = (#{expr}) - spinrail_before\n" \
            "spinrail_assert(spinrail_change == #{diff}, #{at}, \"#{expr} changed by \" + spinrail_change.to_s + \", expected #{diff}\")"
        end
      end
      true
    end

    # Rails.cache.fetch/read/write/delete/clear
    def rails_cache_call?(node)
      recv = node.receiver
      recv.is_a?(Prism::CallNode) && recv.name == :cache && recv.receiver.is_a?(Prism::ConstantReadNode) &&
        recv.receiver.name == :Rails && %i[fetch read write delete clear exist?].include?(node.name)
    end

    def lower_rails_cache(node)
      args, kw = Spinrail.call_args(node)
      ttl = kw[:expires_in] ? "(#{@rw.slice(kw[:expires_in])})" : "0"
      @rw.replace(node) do
        key = args[0] ? "(#{@rw.slice(args[0])}).cache_key" : '""'
        case node.name
        when :fetch then "Spinrail.cache_fetch(#{key}, #{ttl}) { #{node.block&.body ? @rw.slice(node.block.body) : '""'} }"
        when :read then "Spinrail.cache.read(#{key})"
        when :exist? then "!Spinrail.cache.read(#{key}).nil?"
        when :write then "Spinrail.cache.write(#{key}, (#{@rw.slice(args[1])}).to_s, #{ttl})"
        when :delete then "Spinrail.cache.delete(#{key})"
        when :clear then "Spinrail.cache.clear"
        end
      end
    end

    # <% cache @post do %>...<% end %>: the block's markup is stored under
    # the key (a string, or a record's cache_key) and reused.
    def lower_fragment_cache(node)
      args, kw = Spinrail.call_args(node)
      ttl = kw[:expires_in] ? "(#{@rw.slice(kw[:expires_in])})" : "0"
      @rw.replace(node) do
        key = "\"views/\" + (#{@rw.slice(args[0])}).cache_key"
        body = node.block.body ? @rw.slice(node.block.body) : ""
        "spinrail_fragment = Spinrail.cache.read(#{key})\nif spinrail_fragment.nil?\n  spinrail_outer = out\n  out = +\"\"\n" \
          "#{body}\n  spinrail_fragment = Spinrail.cache.write(#{key}, out, #{ttl})\n  out = spinrail_outer\nend\nout << spinrail_fragment"
      end
    end

    # UserMailer.welcome(user) -> UserMailer.new.welcome(user)
    def mailer_call?(node)
      node.receiver.is_a?(Prism::ConstantReadNode) && @ctx.mailer_names.include?(node.receiver.name.to_s) &&
        !%i[new deliver_now deliver_later].include?(node.name)
    end

    # mail(to:, subject:, from:) renders <mailer>/<action>.text.erb and
    # .html.erb with the ivars the action assigned.
    def lower_mail(node)
      _, kw = Spinrail.call_args(node)
      fail!(node, "mail needs to:") unless kw[:to]
      action = @ctx.current_def
      bodies = %w[text html].map do |format|
        t = @ctx.template(format == "text" ? "#{@ctx.dir}/#{action}.text" : "#{@ctx.dir}/#{action}")
        next '""' unless t
        missing = t.exposures - @ctx.assigned
        fail!(node, "#{t.key} reads #{missing.map { |m| "@#{m}" }.join(', ')}, which ##{action} doesn't assign") if missing.any?
        "ApplicationView.new(self).#{t.method_name}#{t.exposures.empty? ? '' : "(#{t.exposures.map { |e| "@#{e}" }.join(', ')})"}"
      end
      fail!(node, "no app/views/#{@ctx.dir}/#{action}.text.erb or .html.erb") if bodies.all? { |b| b == '""' }
      @rw.replace(node) do
        s = ->(k) { kw[k] ? "(#{@rw.slice(kw[k])}).to_s" : '""' }
        "spinrail_mail(#{s.(:to)}, #{s.(:from)}, #{s.(:subject)}, #{bodies[0]}, #{bodies[1]})"
      end
    end

    # WelcomeJob.perform_later(x): jobs take one argument, passed as a String.
    def job_call?(node)
      %i[perform_later perform_now].include?(node.name) &&
        (node.receiver.is_a?(Prism::ConstantReadNode) || node.receiver.is_a?(Prism::ConstantPathNode)) &&
        node.receiver.slice.end_with?("Job") && (node.arguments.nil? || node.arguments.arguments.size == 1)
    end

    def request_params?(node)
      node.is_a?(Prism::CallNode) && node.name == :params && node.arguments.nil? &&
        (local?(node.receiver, :request) || bare?(node.receiver, :request))
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
      args, kw = Spinrail.call_args(node)
      @rw.replace(node) do
        recv = @rw.slice(node.receiver)
        case node.name
        when :require then "#{recv}.require_key(#{Spinrail.literal(args.first).to_s.inspect})"
        when :permit then "#{recv}.permit_keys(#{args.map { |a| Spinrail.literal(a).to_s }.inspect})"
        when :expect
          key, fields = kw.first
          "#{recv}.require_key(#{key.to_s.inspect}).permit_keys(#{Spinrail.literal(fields).map(&:to_s).inspect})"
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
      args, kw = Spinrail.call_args(node)
      fail!(node, "form_with takes keyword options") unless args.empty?
      var = node.block.parameters&.parameters&.requireds&.first&.name or fail!(node, "form_with needs a block parameter")
      model = kw[:model]
      parent = nil
      if model.is_a?(Prism::ArrayNode)
        fail!(node, "form_with model: [parent, record]") unless model.elements.size == 2
        parent, model = model.elements
      end
      scope = kw[:scope] ? Spinrail.literal(kw[:scope]).to_s : model ? model_scope(model) : ""
      @forms << { var: var, scope: scope, model: model }
      attrs = html_attrs(kw.reject { |k, _| %i[model scope url method local multipart].include?(k) })
      # A file field makes the form multipart, as in Rails.
      if (kw[:multipart] && Spinrail.literal(kw[:multipart]) == true) || file_field?(node.block)
        attrs = "#{attrs} + \" enctype=\\\"multipart/form-data\\\"\""
      end
      @rw.replace(node) do
        m = model && @rw.slice(model)
        url = if kw[:url] then @rw.slice(kw[:url])
              elsif parent then nested_model_url(node, model_scope(parent), @rw.slice(parent), scope, m)
              else model_url(node, scope, m)
              end
        method = if kw[:method] then Spinrail.literal(kw[:method]).to_s.inspect
                 elsif m then "(#{m}.persisted? ? \"patch\" : \"post\")"
                 else '"post"'
                 end
        body = node.block.body ? @rw.slice(node.block.body) : ""
        "out << form_open(#{url}, #{method}, #{attrs})\n#{body}\nout << \"</form>\""
      end
    end

    def file_field?(node)
      return true if node.is_a?(Prism::CallNode) && node.name == :file_field
      node.compact_child_nodes.any? { |child| file_field?(child) }
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
      args, kw = Spinrail.call_args(node)
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
      when :file_field then "form_file(#{scope}, #{attr.inspect}, #{attrs})"
      when :check_box, :checkbox then "form_check_box(#{scope}, #{attr.inspect}, #{value.("")}, #{attrs})"
      when :select
        fail!(node, "f.select(:attr, choices)") unless args[1]
        "form_select(#{scope}, #{attr.inspect}, #{value.(".to_s")}, #{@rw.slice(args[1])}, #{attrs})"
      when :collection_select
        fail!(node, "f.collection_select(:attr, records, :value_method, :text_method)") unless args.size == 4
        coll = "(#{@rw.slice(args[1])}).to_a"
        v, t = Spinrail.literal(args[2]), Spinrail.literal(args[3])
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
      return %i[t translate l localize locale locale=].include?(node.name) if i18n
      node.receiver.nil? && %i[t translate l localize].include?(node.name) && node.arguments
    end

    # t("key"), t(".lazy") (scoped to the template, or controller.action),
    # t("key", name: value), I18n.locale and I18n.locale = "es".
    def lower_i18n(node)
      case node.name
      when :locale then return @rw.replace(node) { "Spinrail.locale" }
      when :locale= then return @rw.replace(node) { "Spinrail.set_locale((#{@rw.slice(node.arguments.arguments.first)}).to_s)" }
      end
      args, kw = Spinrail.call_args(node)
      if %i[l localize].include?(node.name)
        format = kw[:format] ? Spinrail.literal(kw[:format]).to_s : "default"
        return @rw.replace(node) { "Spinrail.localize((#{@rw.slice(args.first)}).to_s, #{format.inspect})" }
      end
      key_node = args.first or fail!(node, "t needs a key")
      literal = key_node.is_a?(Prism::StringNode) || key_node.is_a?(Prism::SymbolNode)
      static = literal && (key_node.unescaped.start_with?(".") ? "#{lazy_scope(node)}#{key_node.unescaped}" : key_node.unescaped)
      @rw.replace(node) do
        key = static ? static.inspect : "(#{@rw.slice(key_node)}).to_s"
        if kw.key?(:count)
          rest = kw.reject { |k, _| k == :count }
          "Spinrail.t_count(#{key}, #{@rw.slice(kw[:count])}, #{rest.keys.map(&:to_s).inspect}, " \
            "[#{rest.values.map { |v| "(#{@rw.slice(v)}).to_s" }.join(', ')}])"
        elsif kw.empty?
          "Spinrail.t(#{key})"
        else
          "Spinrail.t_with(#{key}, #{kw.keys.map(&:to_s).inspect}, [#{kw.values.map { |v| "(#{@rw.slice(v)}).to_s" }.join(', ')}])"
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
        unless stmt.is_a?(Prism::CallNode) && local?(stmt.receiver, var) && %i[html json turbo_stream].include?(stmt.name)
          fail!(stmt, "respond_to supports format.html, format.json and format.turbo_stream")
        end
        [stmt.name, stmt.block&.body]
      end
      # Turbo Stream first: Turbo's Accept header also lists text/html.
      tests = { turbo_stream: "wants_turbo_stream?", json: "wants_json?", html: "!wants_json?" }
      branches = branches.sort_by { |format, _| tests.keys.index(format) }
      @rw.replace(node) do
        code = branches.map.with_index do |(format, body), i|
          "#{i.zero? ? 'if' : 'elsif'} #{tests[format]}\n#{body ? @rw.slice(body) : 'nil'}"
        end
        code.join("\n") + "\nelse\nhead(406)\nend"
      end
    end

    # Stored on the controller: the page and its layout are rendered by
    # different view instances. The block form captures what it writes.
    def lower_content_for(node)
      args, = Spinrail.call_args(node)
      key = Spinrail.literal(args.first).to_s.inspect
      @rw.replace(node) do
        if node.name == :content_for?
          "content_for?(#{key})"
        elsif node.block
          body = node.block.body ? @rw.slice(node.block.body) : ""
          "spinrail_outer = out\nout = +\"\"\n#{body}\ncontent_for_set(#{key}, out)\nout = spinrail_outer"
        elsif args[1]
          "content_for_set(#{key}, (#{@rw.slice(args[1])}).to_s)"
        else
          "content_for_get(#{key}).to_s"
        end
      end
    end

    # <%= link_to path, class: "x" do %>...<% end %>, inlined like form_with.
    def lower_link_block(node)
      args, kw = Spinrail.call_args(node)
      fail!(node, "link_to with a block takes the url") unless args.size == 1
      @rw.replace(node) do
        open = "\"<a href=\\\"\" + h((#{@rw.slice(args[0])}).to_s) + \"\\\"\" + #{html_attrs(kw)} + \">\""
        body = node.block.body ? @rw.slice(node.block.body) : ""
        "out << #{open}\n#{body}\nout << \"</a>\""
      end
    end

    # turbo_frame_tag "id" do ... end, or turbo_frame_tag "id", src: path
    def lower_turbo_frame(node)
      args, kw = Spinrail.call_args(node)
      @rw.replace(node) do
        open = "\"<turbo-frame id=\\\"\" + h((#{@rw.slice(args.first)}).to_s) + \"\\\"\" + #{html_attrs(kw)} + \">\""
        if node.block
          body = node.block.body ? @rw.slice(node.block.body) : ""
          "out << #{open}\n#{body}\nout << \"</turbo-frame>\""
        else
          "(#{open} + \"</turbo-frame>\")"
        end
      end
    end

    def lower_link(node)
      args, kw = Spinrail.call_args(node)
      fail!(node, "#{node.name}(text, url, html_options)") unless args.size == 2
      method = kw[:method] ? Spinrail.literal(kw[:method]).to_s : "post"
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
          value.elements.map { |a| attr_part("data-#{Spinrail.literal(a.key).to_s.tr('_', '-')}", a.value) }
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
        %( #{name}="#{CGI.escapeHTML(Spinrail.literal(value).to_s)}").inspect
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

    # order("sql") as is; order(:a, :b) as order(a: :asc, b: :asc).
    def order_call(prefix, args)
      return "#{prefix}order_sql(#{@rw.slice(args.first)})" if args.first.is_a?(Prism::StringNode)
      "#{prefix}order(#{args.map { |a| "#{a.unescaped}: :asc" }.join(', ')})"
    end

    def lower_query(node)
      recv = node.name == :not ? node.receiver.receiver : node.receiver
      prefix = -> { recv ? "#{@rw.slice(recv)}." : "" }
      arg = node.arguments&.arguments&.first
      @rw.replace(node) do
        case node.name
        when :not then "#{prefix.call}where_not(#{@rw.slice(arg)})"
        when :pluck then "#{prefix.call}pluck_#{arg.unescaped}"
        when :order then order_call(prefix.call, node.arguments.arguments)
        when :exists? then "#{prefix.call}where(#{@rw.slice(arg)}).exists?"
        when :includes, :preload, :eager_load
          names = node.arguments.arguments.map { |a| Spinrail.literal(a).to_s }
          "#{prefix.call}with_includes(#{names.inspect})"
        when :joins
          "#{prefix.call}with_joins(#{node.arguments.arguments.map { |a| a.unescaped }.inspect})"
        when :left_joins, :left_outer_joins
          "#{prefix.call}with_joins(#{node.arguments.arguments.map { |a| "left:#{a.unescaped}" }.inspect})"
        when :where then lower_nested_where(prefix.call, arg)
        when :count
          group = node.receiver
          column = Spinrail.literal(group.arguments.arguments.first).to_s
          "#{group.receiver ? "#{@rw.slice(group.receiver)}." : ''}group_count(#{column.inspect})"
        end
      end
    end

    def record_ivar_write(node)
      fail!(node, "templates can't assign instance variables") if @ctx.view?
      @ctx.assign(node.name.to_s.delete_prefix("@"))
    end

    # params[:post][:title] -> the form name "post[title]".
    def nested_params_path(node)
      return nil unless node.is_a?(Prism::CallNode) && node.name == :[] && node.arguments&.arguments&.size == 1
      key = node.arguments.arguments.first
      return nil unless key.is_a?(Prism::SymbolNode) || key.is_a?(Prism::StringNode)
      recv = node.receiver
      return [Spinrail.literal(recv.arguments.arguments.first).to_s, key.unescaped] if recv.is_a?(Prism::CallNode) && params_lookup?(recv)
      inner = recv.is_a?(Prism::CallNode) && nested_params_path(recv)
      inner && inner + [key.unescaped]
    end

    def params_lookup?(node)
      return false unless node.name == :[] && node.arguments&.arguments&.size == 1
      recv = node.receiver
      return false unless recv.is_a?(Prism::CallNode) && recv.name == :params && recv.arguments.nil?
      recv.receiver.nil? || local?(recv.receiver, :request) || bare?(recv.receiver, :request)
    end

    def local?(node, name)
      node.is_a?(Prism::LocalVariableReadNode) && node.name == name
    end

    # Action classes: response.render(view, name: value, ...) passes the
    # view's exposures by name; the build checks them against `expose`.
    def lower_action_render(node)
      args, kw = Spinrail.call_args(node)
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
      args, = Spinrail.call_args(node)
      fail!(node, "halt takes a status and an optional body") unless (1..2).cover?(args.size)
      code = status_code(args[0])
      @ctx.record_response(nil, where(node))
      @rw.replace(node) do
        body = args[1] ? "(#{@rw.slice(args[1])}).to_s" : "Tep.reason(#{code})"
        "return render_plain(#{body}, #{code})"
      end
    end

    def lower_redirect(node)
      args, kw = Spinrail.call_args(node)
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
      args, kw = Spinrail.call_args(node)
      @ctx.view? ? lower_partial(node, args, kw) : lower_template(node, args, kw)
    end

    def lower_template(node, args, kw)
      status = kw[:status] ? status_code(kw[:status]) : 200
      if kw[:view]
        # render view: Views::Stats::Show, count: ... -- a Hanami-style view from a controller.
        exposures = kw.reject { |k, _| %i[view status].include?(k) }
        key = Spinrail.class_key(kw[:view].slice, "Views") or fail!(node, "expected view: Views::..., got `#{kw[:view].slice}`")
        view = @ctx.view_for(key, exposures.keys, where(node))
        @ctx.record_response(nil, where(node))
        @rw.replace(node) do
          values = view.exposures.map { |e| @rw.slice(exposures.fetch(e.to_sym)) }
          "render_view(ApplicationView.new(self).#{view.method_name}(#{values.join(', ')}), #{status})"
        end
      elsif kw[:turbo_stream]
        @ctx.record_response(nil, where(node))
        streams = kw[:turbo_stream].is_a?(Prism::ArrayNode) ? kw[:turbo_stream].elements : [kw[:turbo_stream]]
        @rw.replace(node) { "render_turbo_stream(#{streams.map { |n| "(#{@rw.slice(n)})" }.join(' + ')}, #{status})" }
      elsif kw[:json]
        @ctx.record_response(nil, where(node))
        @rw.replace(node) { "render_json(#{json(kw[:json])}, #{status})" }
      elsif kw[:plain]
        @ctx.record_response(nil, where(node))
        @rw.replace(node) { "render_plain(#{@rw.slice(kw[:plain])}, #{status})" }
      elsif args.first
        name = Spinrail.literal(args.first).to_s
        template = name.include?("/") ? name : "#{@ctx.dir}/#{name}"
        method = @ctx.render_method(template) or fail!(node, "missing template app/views/#{template}.html.erb")
        @ctx.record_response(template, where(node))
        layout = ""
        if kw.key?(:layout)
          value = Spinrail.literal(kw[:layout])
          layout = value ? value.to_s : "none"
          fail!(node, "no app/views/layouts/#{layout}.html.erb") if value && !@ctx.layout?(layout)
        end
        @rw.replace(node) { layout.empty? ? "#{method}(#{status})" : "#{method}(#{status}, #{layout.inspect})" }
      else
        fail!(node, "unsupported render: `#{node.slice}`")
      end
    end

    TURBO_ACTIONS = %i[append prepend replace update remove before after].freeze

    # turbo_stream.append("entries", partial: "entries/entry", locals: { entry: @entry })
    # or a string of HTML as the second argument.
    def turbo_stream_call?(node)
      TURBO_ACTIONS.include?(node.name) && bare?(node.receiver, :turbo_stream)
    end

    def lower_turbo_stream(node)
      args, kw = Spinrail.call_args(node)
      fail!(node, "turbo_stream.#{node.name}(target, ...)") unless args.first
      content = if node.name == :remove then nil
                elsif kw[:partial]
                  name = Spinrail.literal(kw[:partial]).to_s
                  dir, base = name.include?("/") ? [File.dirname(name), File.basename(name)] : [@ctx.dir, name]
                  locals = kw[:locals] ? kw[:locals].elements.to_h { |e| [Spinrail.literal(e.key), e.value] } : {}
                  method, keywords = @ctx.partial_method("#{dir}/_#{base}", locals.keys, where(node))
                  [method, keywords, locals]
                elsif args[1] then args[1]
                end
      @rw.replace(node) do
        html = case content
               when nil then '""'
               when Array
                 method, keywords, locals = content
                 "ApplicationView.new(self).#{method}(#{locals.map { |k, v| keywords ? "#{k}: #{@rw.slice(v)}" : @rw.slice(v) }.join(', ')})"
               else "(#{@rw.slice(content)}).to_s"
               end
        "turbo_stream_tag(#{node.name.to_s.inspect}, (#{@rw.slice(args.first)}).to_s, #{html})"
      end
    end

    def lower_head(node)
      args, = Spinrail.call_args(node)
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
        name = Spinrail.literal(kw[:partial]).to_s
        return lower_collection(node, name, kw[:collection], kw[:as] ? Spinrail.literal(kw[:as]).to_s : File.basename(name))
      end
      fail!(node, "render in views takes a partial name: render \"name\", local: value") unless args.size == 1
      name = Spinrail.literal(args.first).to_s
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
      value = Spinrail.literal(node)
      return value if value.is_a?(Integer)
      STATUS.fetch(value) { fail!(node, "unknown status :#{value}") }
    end

    def fail!(node, message)
      raise CompileError, "#{@file}:#{node.location.start_line}: #{message}"
    end
  end
end
