module Rieles
  # controller is a path ("posts", "admin/posts"); nil for action classes.
  Route = Struct.new(:verb, :path, :controller, :action)

  # Reads config/routes.rb: root, resources/resource (nested, member,
  # collection), namespace and verb routes, plus their path helpers.
  class Routes
    RESOURCE_ACTIONS = %i[index new create show edit update destroy].freeze
    SINGULAR_ACTIONS = %i[new create show edit update destroy].freeze
    VERBS = %i[get post patch put delete].freeze

    # One level of nesting: where paths, helper names and controllers start.
    # base_path/base_helper exclude resource nesting, for shallow routes.
    Scope = Struct.new(:path, :helper, :module, :params, :kind, :base_path, :base_helper, :shallow)

    attr_reader :routes, :helpers

    def initialize(file)
      @file = file
      @routes = []
      @helpers = {} # name => [params, ruby expression]
      @scopes = [Scope.new("", "", "", [], nil, "", "", false)]
      @concerns = {}
      root = Rieles.parse(File.read(file), file)
      draw = find_draw(root) or fail!(root, "expected Rieles.routes.draw do ... end")
      body(draw.block)
    end

    private

    def scope = @scopes.last

    def find_draw(node)
      return node if node.is_a?(Prism::CallNode) && node.name == :draw && node.block
      node.compact_child_nodes.each do |child|
        found = find_draw(child)
        return found if found
      end
      nil
    end

    def body(block)
      (block&.body&.body || []).each { |stmt| statement(stmt) }
    end

    def statement(node)
      fail!(node, "unexpected `#{node.slice.lines.first.strip}` in routes") unless node.is_a?(Prism::CallNode) && node.receiver.nil?
      case node.name
      when :root then root(node)
      when :resources then resources(node, plural: true)
      when :resource then resources(node, plural: false)
      when :namespace then namespace(node)
      when :scope then path_scope(node)
      when :concern then @concerns[Rieles.literal(Rieles.call_args(node).first.first)] = node.block
      when :shallow then within(scope.dup.tap { |sc| sc.shallow = true }) { body(node.block) }
      when :member, :collection then nest_kind(node)
      when *VERBS then verb(node)
      else fail!(node, "unsupported route `#{node.name}`")
      end
    end

    def root(node)
      args, kw = Rieles.call_args(node)
      target = args.first || kw[:to]
      controller, action = endpoint(node, target)
      add(:get, scope.path.empty? ? "/" : scope.path, controller, action)
      helper("#{scope.helper}root", [], (scope.path.empty? ? "/" : scope.path).inspect)
    end

    def namespace(node)
      args, = Rieles.call_args(node)
      name = Rieles.literal(args.first).to_s
      within(Scope.new("#{scope.path}/#{name}", "#{scope.helper}#{name}_", "#{scope.module}#{name}/", scope.params, nil,
                       "#{scope.base_path}/#{name}", "#{scope.base_helper}#{name}_", scope.shallow)) do
        body(node.block)
      end
    end

    # scope "/prefix", module: "admin", as: "admin" -- each part optional.
    def path_scope(node)
      args, kw = Rieles.call_args(node)
      prefix = args.first ? "/#{Rieles.literal(args.first).to_s.delete_prefix('/')}" : ""
      mod = kw[:module] ? "#{Rieles.literal(kw[:module])}/" : ""
      as = kw[:as] ? "#{Rieles.literal(kw[:as])}_" : ""
      within(Scope.new("#{scope.path}#{prefix}", "#{scope.helper}#{as}", "#{scope.module}#{mod}", scope.params, nil,
                       "#{scope.base_path}#{prefix}", "#{scope.base_helper}#{as}", scope.shallow)) do
        body(node.block)
      end
    end

    def nest_kind(node)
      fail!(node, "#{node.name} only goes inside resources") unless @resource
      kind_scope = scope.dup
      kind_scope.kind = node.name
      within(kind_scope) { body(node.block) }
    end

    def verb(node)
      args, kw = Rieles.call_args(node)
      if scope.kind
        return member_route(node, args, kw)
      end
      path = Rieles.literal(args.first).to_s
      path = "/#{path}" unless path.start_with?("/")
      fail!(node, "#{node.name} needs `to: \"controller#action\"`") unless kw[:to]
      controller, action = endpoint(node, kw[:to])
      full = "#{scope.path}#{path}"
      add(node.name, full, controller, action)
      name = kw[:as] ? Rieles.literal(kw[:as]).to_s : path.delete_prefix("/").tr("/-", "__")
      return if name.empty? || name.include?(":")
      params = full.scan(/:(\w+)/).flatten
      helper("#{scope.helper}#{name}", params, path_expr(full))
    end

    # Inside member/collection: `post :publish` -> posts#publish.
    def member_route(node, args, kw)
      action = Rieles.literal(args.first).to_s
      r = @resource
      to = kw[:to] ? endpoint(node, kw[:to]) : [r[:controller], action]
      if scope.kind == :member && r[:plural]
        path = "#{r[:member]}/#{action}"
        add(node.name, path, *to)
        helper("#{action}_#{r[:member_helper]}", r[:member_params] + ["id"], path_expr(path))
      else
        path = "#{r[:base]}/#{action}"
        @collection_routes << [node.name, path, *to]
        helper("#{action}_#{r[:plural] ? r[:helper_plural] : r[:helper_single]}", r[:params], path_expr(path))
      end
    end

    def resources(node, plural:)
      args, kw = Rieles.call_args(node)
      name = Rieles.literal(args.first).to_s
      all = plural ? RESOURCE_ACTIONS : SINGULAR_ACTIONS
      actions = kw[:only] ? Array(Rieles.literal(kw[:only])) : all
      actions -= Array(Rieles.literal(kw[:except])) if kw[:except]
      single = plural ? Inflector.singularize(name) : name
      controller = scope.module + (kw[:controller] ? Rieles.literal(kw[:controller]).to_s : (plural ? name : Inflector.pluralize(name)))
      base = "#{scope.path}/#{name}"
      shallow = (kw[:shallow] ? Rieles.literal(kw[:shallow]) : scope.shallow) && !scope.params.empty?
      member_base = shallow ? "#{scope.base_path}/#{name}" : base
      member = plural ? "#{member_base}/:id" : base
      member_params = shallow ? [] : scope.params
      member_helper = shallow ? "#{scope.base_helper}#{single}" : "#{scope.helper}#{single}"
      outer = @resource
      @resource = {
        plural: plural, controller: controller, base: base, member: member, params: scope.params,
        helper_single: "#{scope.helper}#{single}", helper_plural: "#{scope.helper}#{name}",
        member_helper: member_helper, member_params: member_params
      }
      @collection_routes = []

      # member/collection and nested resources are read first so collection
      # routes (/posts/search) can be registered before /posts/:id.
      deferred = []
      saved = @routes
      @routes = []
      nested_param = "#{single}_id"
      concern_nodes = Array(kw[:concerns] ? Rieles.literal(kw[:concerns]) : []).flat_map do |c|
        block = @concerns[c] or fail!(node, "unknown concern :#{c}")
        block.body&.body || []
      end
      ((node.block&.body&.body || []) + concern_nodes).each do |stmt|
        if stmt.is_a?(Prism::CallNode) && %i[member collection].include?(stmt.name)
          statement(stmt)
        else
          deferred << stmt
        end
      end
      member_routes = @routes
      @routes = saved

      collection_path = plural ? base : nil
      helper_params = scope.params
      all.each do |action|
        next unless actions.include?(action)
        case action
        when :index then add(:get, base, controller, action)
        when :new
          add(:get, "#{base}/new", controller, action)
          @collection_routes.each { |r| add(*r) }
          @collection_routes = []
        when :create then add(:post, base, controller, action)
        when :show then add(:get, member, controller, action)
        when :edit then add(:get, "#{member}/edit", controller, action)
        when :update then add(:patch, member, controller, action); add(:put, member, controller, action)
        when :destroy then add(:delete, member, controller, action)
        end
      end
      @collection_routes.each { |r| add(*r) }
      member_routes.each { |r| @routes << r }

      ids = plural ? member_params + ["id"] : helper_params
      if (actions & %i[index create]).any? && plural
        helper(@resource[:helper_plural], helper_params, path_expr(base))
      end
      helper("new_#{@resource[:helper_single]}", helper_params, path_expr("#{base}/new")) if actions.include?(:new)
      member_actions = plural ? %i[show update destroy] : %i[show create update destroy]
      helper(member_helper, ids, path_expr(member)) if (actions & member_actions).any?
      helper("edit_#{member_helper}", ids, path_expr("#{member}/edit")) if actions.include?(:edit)

      unless deferred.empty?
        nested_path = plural ? "#{base}/:#{nested_param}" : base
        nested_params = plural ? helper_params + [nested_param] : helper_params
        within(Scope.new(nested_path, "#{@resource[:helper_single]}_", scope.module, nested_params, nil,
                         scope.base_path, scope.base_helper, scope.shallow || kw[:shallow] && Rieles.literal(kw[:shallow]))) do
          deferred.each { |stmt| statement(stmt) }
        end
      end
      @resource = outer
    end

    def within(new_scope)
      @scopes.push(new_scope)
      yield
    ensure
      @scopes.pop
    end

    def add(verb, path, controller, action)
      @routes << Route.new(verb, path, controller, action.to_s)
    end

    def helper(name, params, expr)
      @helpers["#{name}_path"] = [params, expr]
    end

    # "/posts/:post_id/comments/:id" -> "/posts/" + post_id.to_param + ...
    def path_expr(path)
      parts = path.split(/(:\w+)/).reject(&:empty?)
      parts.map { |p| p.start_with?(":") ? "#{p[1..]}.to_param" : p.inspect }.join(" + ")
    end

    # "entries#index" is a controller action; Actions::Stats::Show an action
    # class, returned as its key with a nil controller.
    def endpoint(node, target)
      return [nil, constant_key(node, target)] if target.is_a?(Prism::ConstantReadNode) || target.is_a?(Prism::ConstantPathNode)
      value = Rieles.literal(target).to_s
      controller, action = value.split("#", 2)
      fail!(node, "expected \"controller#action\" or Actions::..., got #{value.inspect}") unless action
      [scope.module + controller, action]
    end

    def constant_key(node, target)
      Rieles.class_key(target.slice, "Actions") or fail!(node, "expected Actions::..., got `#{target.slice}`")
    end

    def fail!(node, message)
      raise CompileError, "#{@file}:#{node.location.start_line}: #{message}"
    end
  end
end
