module Rieles
  Route = Struct.new(:verb, :path, :controller, :action)

  class Routes
    RESOURCE_ACTIONS = %i[index new create show edit update destroy].freeze

    attr_reader :routes, :helpers

    def initialize(file)
      @file = file
      @routes = []
      @helpers = {} # name => [param, ruby expression]
      walk(Rieles.parse(File.read(file), file))
    end

    private

    def walk(node)
      if node.is_a?(Prism::CallNode) && node.receiver.nil?
        case node.name
        when :root then root(node)
        when :resources then resources(node)
        when :get, :post, :patch, :put, :delete then verb(node)
        end
      end
      node.compact_child_nodes.each { |child| walk(child) }
    end

    def root(node)
      args, = Rieles.call_args(node)
      controller, action = endpoint(node, args.first)
      @routes << Route.new(:get, "/", controller, action)
      @helpers["root_path"] = [nil, '"/"']
    end

    def verb(node)
      args, kw = Rieles.call_args(node)
      path = Rieles.literal(args.first)
      fail!(node, "#{node.name} needs `to: \"controller#action\"`") unless kw[:to]
      controller, action = endpoint(node, kw[:to])
      @routes << Route.new(node.name, path, controller, action)
      name = kw[:as] ? Rieles.literal(kw[:as]).to_s : path.delete_prefix("/").tr("/-", "__")
      @helpers["#{name}_path"] = [nil, path.inspect] unless path.include?(":") || name.empty?
    end

    def resources(node)
      args, kw = Rieles.call_args(node)
      name = Rieles.literal(args.first).to_s
      actions = kw[:only] ? Rieles.literal(kw[:only]) : RESOURCE_ACTIONS
      actions -= Rieles.literal(kw[:except]) if kw[:except]
      base = "/#{name}"
      member = "#{base}/:id"
      single = Inflector.singularize(name)
      member_expr = ->(suffix) { "#{base.inspect} + \"/\" + record.id.to_s#{suffix}" }

      # Order matters: /entries/new must be registered before /entries/:id.
      RESOURCE_ACTIONS.each do |action|
        next unless actions.include?(action)
        case action
        when :index then add(:get, base, name, action)
        when :new then add(:get, "#{base}/new", name, action)
        when :create then add(:post, base, name, action)
        when :show then add(:get, member, name, action)
        when :edit then add(:get, "#{member}/edit", name, action)
        when :update then add(:patch, member, name, action); add(:put, member, name, action)
        when :destroy then add(:delete, member, name, action)
        end
      end
      @helpers["#{name}_path"] = [nil, base.inspect] if (actions & %i[index create]).any?
      @helpers["new_#{single}_path"] = [nil, "#{base}/new".inspect] if actions.include?(:new)
      @helpers["#{single}_path"] = ["record", member_expr.call("")] if (actions & %i[show update destroy]).any?
      @helpers["edit_#{single}_path"] = ["record", member_expr.call(' + "/edit"')] if actions.include?(:edit)
    end

    def add(verb, path, controller, action)
      @routes << Route.new(verb, path, controller, action.to_s)
    end

    # "entries#index" is a controller action; Actions::Stats::Show an action
    # class, returned as its key with a nil controller.
    def endpoint(node, target)
      return [nil, constant_key(node, target)] if target.is_a?(Prism::ConstantReadNode) || target.is_a?(Prism::ConstantPathNode)
      value = Rieles.literal(target).to_s
      controller, action = value.split("#", 2)
      fail!(node, "expected \"controller#action\" or Actions::..., got #{value.inspect}") unless action
      [controller, action]
    end

    def constant_key(node, target)
      Rieles.class_key(target.slice, "Actions") or fail!(node, "expected Actions::..., got `#{target.slice}`")
    end

    def fail!(node, message)
      raise CompileError, "#{@file}:#{node.location.start_line}: #{message}"
    end
  end
end
