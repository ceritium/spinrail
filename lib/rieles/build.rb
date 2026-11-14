require "set"
require "securerandom"

module Rieles
  # Reads an app laid out like a Rails app and writes one tep source file
  # (Sinatra-style DSL plus plain classes) that `tep build` compiles.
  #
  # Internally every endpoint is action -> view with explicit exposures ->
  # template. A Rails controller method is lowered to that: the @ivars its
  # template reads become the template's parameters, checked against the
  # ivars the action assigns.
  class Build
    # name is "welcome" for welcome.html.erb and "welcome.text" for the
    # plain-text (unescaped) welcome.text.erb that mailers use.
    Template = Struct.new(:path, :dir, :name, :exposures) do
      def partial? = name.start_with?("_")
      def text? = name.end_with?(".text")

      # Rails 7.1 strict locals: <%# locals: (entry:, compact: false) %>
      def strict_locals = @strict_locals ||= [File.read(path)[/\A<%#\s*locals:\s*\((.*?)\)\s*-?%>/m, 1]]
      def strict = strict_locals.first

      def strict_names
        params = Prism.parse("def x(#{strict}); end").value.statements.body.first.parameters
        required = params&.keywords&.select { |k| k.is_a?(Prism::RequiredKeywordParameterNode) }&.map { |k| k.name } || []
        optional = params&.keywords&.select { |k| k.is_a?(Prism::OptionalKeywordParameterNode) }&.map { |k| k.name } || []
        [required, optional]
      end
      def layout? = dir == "layouts"
      def page? = !partial? && !layout?
      def key = "#{dir}/#{name}"

      def method_name
        return "layout_#{name}" if layout?
        "#{partial? ? 'partial' : 'view'}_#{dir.tr('/', '_')}_#{name.delete_prefix('_').tr('.', '_')}"
      end

      # Controller-side method that collects the exposures and renders.
      def render_method = "render_#{method_name}"
    end

    Response = Struct.new(:template, :where)

    # Hanami-style: Views::Stats::Show (`expose :a, :b`) plus
    # app/templates/stats/show.html.erb, whose locals are the exposures.
    # exposures are what the action passes; computed ones (expose :x do |a| ...)
    # are derived from them in the template method; defs become view methods.
    ActionView = Struct.new(:key, :class_name, :exposures, :template_path, :computed, :methods) do
      def method_name = "template_#{key.tr('.', '_')}"
    end

    # Hanami-style action: Actions::Stats::Show, lowered to a flat class
    # that inherits ApplicationController's response helpers.
    ActionClass = Struct.new(:key, :class_name, :source, :file)

    # Precedes each section of the generated source so a spinel error can be
    # pointed back at the app file; lowering keeps controller lines in place.
    SOURCE_MARK = "# rieles:source ".freeze

    Filter = Struct.new(:kind, :name, :only, :except) do
      def applies?(action) = (only.nil? || only.include?(action)) && !except&.include?(action)
    end

    RescueHandler = Struct.new(:exception, :handler)

    # What the lowering records and resolves for one file.
    class Context
      attr_reader :dir, :exposures, :assigns, :responses

      def initialize(build, dir, view:, ivars: true, action: nil, controller: false, test: false, job: false, mailer: false)
        @build = build
        @mailer = mailer
        @job = job
        @controller = controller
        @test = test
        @dir = dir
        @view = view
        @ivars = ivars
        @action = action
        @current = nil
        @exposures = {}
        @assigns = Hash.new { |h, k| h[k] = Set.new }
        @responses = Hash.new { |h, k| h[k] = [] }
      end

      def view? = @view
      def test? = @test
      def job? = @job
      def mailer? = @mailer
      def mailer_names = @build ? @build.mailer_names : []
      def template(key) = @build&.templates&.[](key)
      def assigned = @assigns[@current].to_a
      def fixture_tables = @build ? @build.fixture_tables : []
      def controller? = @controller
      def action? = !@action.nil?
      def enter_def(name) = @current = name

      def action_view(keys, where) = view_for(@action, keys, where)

      def view_for(key, keys, where)
        view = @build.action_views[key] or
          raise CompileError, "#{where}: no app/views/#{key.tr('.', '/')}.rb for #{Rieles.class_name(key, "Views")}"
        given = keys.map(&:to_s).sort
        unless given == view.exposures.sort
          raise CompileError, "#{where}: #{view.class_name} exposes #{view.exposures.inspect}, render passes #{given.inspect}"
        end
        view
      end
      def assign(name) = @assigns[@current] << name

      def record_response(template, where)
        @responses[@current] << Response.new(template, where)
      end

      def expose(name, where)
        raise CompileError, "#{where}: partials and layouts only see their locals, not @#{name}" unless @ivars
        @exposures[name] ||= where
      end

      def render_method(key)
        t = @build.templates[key]
        t&.page? ? t.render_method : nil
      end

      def partial_method(key, locals, where) = @build.use_partial(key, locals, where)
      attr_accessor :i18n_scope

      def path_helper?(name) = @build.routes.helpers.key?(name)
      def associations_of(model) = @build ? @build.associations.fetch(model, []) : []
      def warn(message) = @build&.warnings&.push(message)
      def current_def = @current
      def layout?(name) = @build.templates.key?("layouts/#{name}")
      def model?(name) = @build.model_names.include?(name)
    end

    attr_reader :templates, :action_views

    def model_names
      @model_names ||= Dir[path("app/models/*.rb")].map { |f| Inflector.camelize(File.basename(f, ".rb")) } - ["ApplicationRecord"]
    end

    def mailer_names = Dir[path("app/mailers/*.rb")].map { |f| Inflector.camelize(File.basename(f, ".rb")) }
    def fixture_tables = Dir[path("test/fixtures/*.yml")].map { |f| File.basename(f, ".yml") }

    # Non-fatal findings (possible N+1 queries), printed by the CLI.
    def warnings = @warnings ||= []

    # Model name => association names, read from the class bodies.
    def associations
      @associations ||= Dir[path("app/models/*.rb")].to_h do |file|
        names = []
        visit = lambda do |node|
          if node.is_a?(Prism::CallNode) && node.receiver.nil? && %i[has_many has_one belongs_to].include?(node.name)
            arg = node.arguments&.arguments&.first
            names << arg.unescaped if arg.is_a?(Prism::SymbolNode)
          end
          node.compact_child_nodes.each { |c| visit.call(c) }
        end
        visit.call(Rieles.parse(File.read(file), rel(file)))
        [Inflector.camelize(File.basename(file, ".rb")), names]
      end
    end

    # tests: compile test/models/*_test.rb in (the test binary).
    # script: Ruby source to run instead of serving (rieles runner).
    def initialize(app_dir, tests: false, script: nil)
      @app = File.expand_path(app_dir)
      @partial_locals = {}
      @tests = tests
      @script = script
    end

    def routes = @routes ||= Routes.new(path("config/routes.rb"))

    def write(out_dir)
      FileUtils.rm_rf(out_dir)
      FileUtils.mkdir_p(out_dir)
      assets = path("app/assets")
      if Dir.exist?(assets)
        FileUtils.cp_r(assets, File.join(out_dir, "assets"))
        asset_digests.each { |name, digested| FileUtils.cp(File.join(assets, name), File.join(out_dir, "assets", digested.delete_prefix("/"))) }
      end
      out = File.join(out_dir, "app.rb")
      File.write(out, generate)
      out
    end

    # Returns [method name, keywords?]: strict partials take keyword locals.
    def use_partial(key, locals, where)
      template = @templates[key]
      raise CompileError, "#{where}: missing partial app/views/#{key}.html.erb" unless template&.partial?
      if template.strict
        required, optional = template.strict_names
        unknown = locals - required - optional
        raise CompileError, "#{where}: #{key} doesn't declare local #{unknown.first}" if unknown.any?
        missing = required - locals
        raise CompileError, "#{where}: #{key} needs local #{missing.first}" if missing.any?
        return [template.method_name, true]
      end
      known = @partial_locals[key]
      if known && known != locals
        raise CompileError, "#{where}: #{key} is rendered with locals #{locals.inspect} here and #{known.inspect} elsewhere"
      end
      @partial_locals[key] = locals
      [template.method_name, false]
    end

    private

    def path(rel) = File.join(@app, rel)
    def rel(file) = file.delete_prefix("#{@app}/")

    def generate
      schema = migrations.any? ? Schema.from_migrations(migrations) : Schema.new(path("db/schema.rb"))
      @templates = Dir[path("app/views/**/*.{html,text}.erb")].to_h do |file|
        key = rel(file).delete_prefix("app/views/").delete_suffix(".erb").delete_suffix(".html")
        [key, Template.new(file, File.dirname(key), File.basename(key), [])]
      end
      @action_views = load_action_views
      views = compile_views
      controllers = load_controllers
      check_responses(controllers)
      @actions = load_actions

      [
        "# Generated by rieles from #{File.basename(@app)}. Do not edit.",
        "require 'sinatra'",
        # The default prefork server ignores SIGINT while a keep-alive
        # connection is idle (OriPekelman/tep#277).
        *(ENV.fetch("RIELES_SERVER", "scheduled") == "prefork" ? [] : ["set :scheduler, :scheduled"]),
        "Tep.session_secret = ENV.fetch(\"SECRET_KEY_BASE\", #{local_secret.inspect})",
        *(Dir.exist?(path("public")) ? ["set :public_dir, \"public\""] : []),
        File.read(RUNTIME),
        translations,
        assets_source,
        application_record,
        *Dir[path("app/models/*.rb")].sort.reject { |f| f.end_with?("/application_record.rb") }
          .map { |f| "#{SOURCE_MARK}generated #{rel(f)}\n#{Model.new(f, schema).to_ruby}" },
        views,
        mailers_source,
        jobs_source,
        *controllers.sort_by { |name, _| name == "ApplicationController" ? 0 : 1 }
          .map { |_, c| "#{SOURCE_MARK}#{c[:file]}\n#{c[:source]}" },
        application_controller_support,
        *controllers.map { |name, c| render_methods(name, c) }.compact,
        *@actions.values.map { |a| "#{SOURCE_MARK}#{a.file}\n#{a.source}" },
        *(@tests ? model_tests.map { |t| "#{SOURCE_MARK}#{t[:file]}\n#{t[:source]}" } : []),
        seeds_class,
        runner_class,
        schema_setup(schema),
        method_override,
        asset_cache_headers,
        *routes.routes.map { |r| route_block(r, controllers) },
        not_found_block
      ].join("\n")
    end

    # style.css -> /style-<sha256 prefix>.css: a new name whenever the
    # content changes, so browsers can cache assets for good.
    def asset_digests
      @asset_digests ||= Dir[path("app/assets/**/*")].select { |f| File.file?(f) }.sort.to_h do |file|
        name = file.delete_prefix("#{path('app/assets')}/")
        ext = File.extname(name)
        [name, "/#{name.delete_suffix(ext)}-#{Digest::SHA256.file(file).hexdigest[0, 12]}#{ext}"]
      end
    end

    def assets_source
      entries = asset_digests.map { |k, v| "    #{k.inspect} => #{v.inspect}" }
      entries = ['    "" => ""'] if entries.empty?
      "module RielesAssets\n  DIGESTS = {\n#{entries.join(",\n")}\n  }.freeze\nend\n"
    end

    # config/locales/*.yml flattened to "es.posts.index.title" => "...".
    def translations
      flat = {}
      walk = lambda do |prefix, value|
        if value.is_a?(Hash)
          value.each { |k, v| walk.call(prefix.empty? ? k.to_s : "#{prefix}.#{k}", v) }
        else
          flat[prefix] = value.to_s
        end
      end
      Dir[path("config/locales/*.yml")].sort.each { |f| walk.call("", YAML.safe_load_file(f) || {}) }
      flat = { "" => "" } if flat.empty?
      entries = flat.map { |k, v| "    #{k.inspect} => #{v.inspect}" }.join(",\n")
      locales = flat.keys.map { |k| k.split(".").first.to_s }.reject(&:empty?).uniq
      locales = [""] if locales.empty?
      "module RielesTranslations\n  ALL = {\n#{entries}\n  }.freeze\n  LOCALES = #{locales.inspect}.freeze\nend\n"
    end

    # Development secret, kept across builds; production sets SECRET_KEY_BASE.
    def local_secret
      file = path("tmp/local_secret.txt")
      unless File.exist?(file)
        FileUtils.mkdir_p(File.dirname(file))
        File.write(file, SecureRandom.hex(32))
      end
      File.read(file).strip
    end

    def application_record
      file = path("app/models/application_record.rb")
      File.exist?(file) ? File.read(file) : "class ApplicationRecord < Rieles::Record\nend\n"
    end

    def path_helpers
      routes.helpers.flat_map do |name, (params, expr)|
        sig = params.empty? ? "" : "(#{params.join(', ')})"
        url = name.sub(/_path\z/, "_url")
        ["  def #{name}#{sig}\n    #{expr}\n  end",
         "  def #{url}#{sig}\n    request_base_url + #{name}#{sig}\n  end"]
      end.join("\n\n")
    end

    # Helper and view-class methods that return html_safe strings.
    def raw_helpers
      sources = Dir[path("app/helpers/*.rb")].map { |f| File.read(f) } + Dir[path("app/views/**/*.rb")].map { |f| File.read(f) }
      sources.flat_map do |source|
        found = []
        visit = lambda do |node|
          found << node.name.to_s if node.is_a?(Prism::DefNode) && node.slice.include?(".html_safe")
          node.compact_child_nodes.each { |c| visit.call(c) }
        end
        visit.call(Rieles.parse(source, "helpers"))
        found
      end.uniq
    end

    def compile_views
      raw = raw_helpers
      methods = @templates.values.map do |t|
        signature = t.layout? ? "#{t.method_name}(content)" : "#{t.method_name}__SIGNATURE__"
        # A partial's trailing newline would double up inside loops.
        source = t.partial? ? File.read(t.path).chomp : File.read(t.path)
        ruby = Erb.compile(source, signature, layout: t.layout?, raw: raw, escape: !t.text?,
                                              log_as: t.partial? ? nil : rel(t.path).delete_prefix("app/views/"))
        ctx = Context.new(self, t.dir, view: true, ivars: t.page?)
        ctx.i18n_scope = "#{t.dir.tr('/', '.')}.#{t.name.delete_prefix('_').delete_suffix('.text')}"
        lowered = Lowering.lower(ruby, rel(t.path), ctx)
        t.exposures = ctx.exposures.keys.sort
        [t, lowered]
      end
      defs = methods.map do |t, ruby|
        params = if t.partial? && t.strict then [t.strict]
                 elsif t.partial? then @partial_locals.fetch(t.key, [])
                 else t.exposures.map { |n| "iv_#{n}" }
                 end
        "#{SOURCE_MARK}erb #{rel(t.path)}\n" + ruby.sub("__SIGNATURE__", params.empty? ? "" : "(#{params.join(', ')})")
      end
      defs += @action_views.values.map do |v|
        signature = "#{v.method_name}(#{v.exposures.join(', ')})"
        ruby = Erb.compile(File.read(v.template_path), signature, raw: raw, log_as: rel(v.template_path).delete_prefix("app/"))
        derived = v.computed.map { |n, body| "  #{n} = begin\n#{body.gsub(/^\s*/, '    ')}\n  end\n" }.join
        ruby = ruby.sub(/\A(def [^\n]*\n)/) { "#{$1}#{derived}" }
        ctx = Context.new(self, File.dirname(v.key.tr('.', '/')), view: true, ivars: false)
        "#{SOURCE_MARK}erb #{rel(v.template_path)}\n" + Lowering.lower(ruby, rel(v.template_path), ctx)
      end
      defs += @action_views.values.flat_map(&:methods).map do |source|
        Lowering.lower(source, "app/views", Context.new(self, "application", view: true, ivars: false)) + "\n"
      end
      <<~RUBY
        #{SOURCE_MARK}generated app/views
        class ApplicationView < Rieles::View
        end

        class ApplicationView
        #{path_helpers}

        #{view_helpers.gsub(/^(?=.)/, '  ')}

        #{defs.join("\n").gsub(/^(?=.)/, '  ')}end
      RUBY
    end

    # app/helpers modules are pasted into ApplicationView: every view sees
    # every helper, as in Rails.
    def view_helpers
      Dir[path("app/helpers/*.rb")].sort.map do |file|
        mod = Rieles.parse(File.read(file), rel(file)).statements.body.find { |n| n.is_a?(Prism::ModuleNode) }
        raise CompileError, "#{rel(file)}: expected a module" unless mod
        body = (mod.body&.body || []).map { |stmt| stmt.slice.gsub(/^ {#{stmt.location.start_column}}/, "") }.join("\n\n")
        Lowering.lower(body, rel(file), Context.new(self, "application", view: true, ivars: false))
      end.join("\n\n")
    end

    # Actions::Stats::Show / Views::Stats::Show -> "stats.show"
    def namespaced_class(file, namespace)
      klass = Rieles.parse(File.read(file), rel(file)).statements.body.find { |n| n.is_a?(Prism::ClassNode) }
      name = klass&.constant_path&.slice.to_s
      key = Rieles.class_key(name, namespace)
      raise CompileError, "#{rel(file)}: expected `class #{namespace}::...` (compact form)" unless key
      [klass, name, key]
    end

    def load_action_views
      Dir[path("app/views/**/*.rb")].sort.to_h do |file|
        klass, name, key = namespaced_class(file, "Views")
        exposures = []
        computed = []
        methods = []
        (klass.body&.body || []).each do |stmt|
          if stmt.is_a?(Prism::DefNode)
            methods << stmt.slice.gsub(/^ {#{stmt.location.start_column}}/, "")
            next
          end
          unless stmt.is_a?(Prism::CallNode) && stmt.name == :expose && stmt.receiver.nil?
            raise CompileError, "#{rel(file)}:#{stmt.location.start_line}: view classes support `expose` and methods"
          end
          names = Rieles.call_args(stmt).first.map { |a| Rieles.literal(a).to_s }
          if stmt.block
            params = stmt.block.parameters&.parameters&.requireds&.map { |p| p.name.to_s } || []
            unknown = params - exposures - computed.map(&:first)
            raise CompileError, "#{rel(file)}:#{stmt.location.start_line}: #{unknown.first} is not exposed" if unknown.any?
            computed << [names.first, stmt.block.body ? stmt.block.body.slice : "nil"]
          else
            exposures.concat(names)
          end
        end
        template = path("app/templates/#{key.tr('.', '/')}.html.erb")
        raise CompileError, "#{rel(file)}: missing #{rel(template)}" unless File.exist?(template)
        [key, ActionView.new(key, name, exposures, template, computed, methods)]
      end
    end

    def load_actions
      Dir[path("app/actions/**/*.rb")].sort.to_h do |file|
        klass, name, key = namespaced_class(file, "Actions")
        unless (klass.body&.body || []).any? { |d| d.is_a?(Prism::DefNode) && d.name == :handle }
          raise CompileError, "#{rel(file)}: #{name} must define handle(request, response)"
        end
        flat = "#{name.delete_prefix('Actions::').delete(':')}Action"
        header = "class #{name}#{klass.superclass ? " < #{klass.superclass.slice}" : ''}"
        source = File.read(file).sub(header, "class #{flat} < ApplicationController")
        schema = (klass.body&.body || []).find { |n| n.is_a?(Prism::CallNode) && n.name == :params && n.block }
        source = source.sub(/\nend\s*\z/, "\n#{params_validation(schema, rel(file))}end\n") if schema
        lowered = Lowering.lower(source, rel(file), Context.new(self, nil, view: false, action: key))
        [key, ActionClass.new(key, flat, lowered, rel(file))]
      end
    end

    # Hanami-style `params do required(:x).filled(:string) end`, one level of
    # `required(:book).hash do ... end` nesting: generates params_valid? and
    # params_errors on the action.
    def params_validation(node, file)
      checks = params_rules(node.block, "", file)
      "  def params_valid?\n    @params_errors = Rieles::Errors.new(\"\")\n#{checks.map { |c| "    #{c}" }.join("\n")}\n" \
        "    @params_errors.empty?\n  end\n\n  def params_errors\n    params_valid? if @params_errors.nil?\n    @params_errors\n  end\n"
    end

    PARAM_TYPES = {
      string: nil,
      integer: ['/\A[+-]?\d+\z/', "must be an integer"],
      float: ['/\A[+-]?\d+(\.\d+)?\z/', "must be a float"],
      bool: ['/\A(true|false|1|0)\z/', "must be boolean"]
    }.freeze

    def params_rules(block, prefix, file)
      (block.body&.body || []).flat_map do |rule|
        # required(:x).filled(:type) / optional(:x).maybe(:type) / required(:x).hash do ... end
        unless rule.is_a?(Prism::CallNode) && rule.receiver.is_a?(Prism::CallNode) && %i[required optional].include?(rule.receiver.name)
          raise CompileError, "#{file}:#{rule.location.start_line}: expected required(:key).filled(:type) or optional(:key).maybe(:type)"
        end
        key = Rieles.literal(rule.receiver.arguments.arguments.first).to_s
        full = prefix.empty? ? key : "#{prefix}[#{key}]"
        label = key.inspect
        required = rule.receiver.name == :required
        if rule.name == :hash && rule.block
          nested = params_rules(rule.block, full, file).map { |l| "#{l} if params.prefixed?(#{full.inspect})" }
          next ["@params_errors.add(#{label}, \"is missing\") unless params.prefixed?(#{full.inspect})"] + nested if required
          next nested
        end
        type = rule.arguments ? Rieles.literal(rule.arguments.arguments.first) : :string
        pattern, message = PARAM_TYPES.fetch(type) { raise CompileError, "#{file}:#{rule.location.start_line}: unsupported type :#{type}" }
        value = "params.raw(#{full.inspect})"
        lines = []
        lines << "@params_errors.add(#{label}, \"is missing\") unless params.raw?(#{full.inspect})" if required
        lines << "@params_errors.add(#{label}, \"must be filled\") if params.raw?(#{full.inspect}) && #{value}.strip.empty?" if rule.name == :filled
        lines << "@params_errors.add(#{label}, #{message.inspect}) if !#{value}.strip.empty? && !#{value}.strip.match?(#{pattern})" if pattern
        lines
      end
    end

    def load_controllers
      controllers = {}
      Dir[path("app/controllers/**/*_controller.rb")].sort.each do |file|
        dir = rel(file).delete_prefix("app/controllers/").delete_suffix("_controller.rb")
        name = "#{Inflector.camelize(dir)}Controller"
        source = File.read(file)
        klass = Rieles.parse(source, rel(file)).statements.body.find { |n| n.is_a?(Prism::ClassNode) }
        expected = "#{dir.split('/').map { |s| Inflector.camelize(s) }.join('::')}Controller"
        unless klass&.constant_path&.slice == expected
          raise CompileError, "#{rel(file)}: expected class #{expected} (compact form for namespaces)"
        end
        # Admin::PostsController is flattened to AdminPostsController, like actions.
        if expected != name
          header = klass.location.slice.lines.first
          parent = klass.superclass&.slice
          flat_parent = parent&.match?(/::\w*Controller\z/) ? parent.delete(":") : parent
          source = source.sub(header, "class #{name}#{flat_parent ? " < #{flat_parent}" : ''}\n")
          klass = Rieles.parse(source, rel(file)).statements.body.find { |n| n.is_a?(Prism::ClassNode) }
        end
        ctx = Context.new(self, dir, view: false, controller: true)
        lowered = Lowering.lower(source, rel(file), ctx)
        decl = controller_declarations(klass, rel(file))
        lowered = lowered.sub(/\nend\s*\z/, "\n#{decl[:extra].join("\n")}end\n") unless decl[:extra].empty?
        controllers[name] = decl.merge(dir: dir, source: lowered, ctx: ctx, file: rel(file))
      end
      controllers["ApplicationController"] ||= {
        dir: "application", actions: [], filters: [], skips: [], rescues: [], arities: {}, forgery: nil, extra: [],
        source: "class ApplicationController < Rieles::Controller\nend\n",
        ctx: Context.new(self, "application", view: false, controller: true), file: "app/controllers/application_controller.rb"
      }
      @controllers = controllers
    end

    # Public methods are actions; filters and rescue_from are read here
    # and dropped from the generated class.
    def controller_declarations(klass, file)
      decl = { actions: [], filters: [], skips: [], rescues: [], arities: {}, forgery: nil, extra: [] }
      visible = true
      (klass.body&.body || []).each do |stmt|
        if stmt.is_a?(Prism::DefNode)
          decl[:arities][stmt.name.to_s] = stmt.parameters&.requireds&.size.to_i
          decl[:actions] << stmt.name.to_s if visible && stmt.receiver.nil?
          next
        end
        next unless stmt.is_a?(Prism::CallNode) && stmt.receiver.nil?
        args, kw = Rieles.call_args(stmt)
        case stmt.name
        when :private, :protected
          visible = false if args.empty?
          args.each do |a|
            if a.is_a?(Prism::DefNode)
              decl[:arities][a.name.to_s] = a.parameters&.requireds&.size.to_i
            else
              decl[:actions].delete(Rieles.literal(a).to_s)
            end
          end
        when :public
          visible = true if args.empty?
        when :before_action, :after_action, :skip_before_action, :skip_after_action
          only = kw[:only] && Array(Rieles.literal(kw[:only])).map(&:to_s)
          except = kw[:except] && Array(Rieles.literal(kw[:except])).map(&:to_s)
          unknown = kw.keys - %i[only except]
          raise CompileError, "#{file}:#{stmt.location.start_line}: unsupported option #{unknown.first}" if unknown.any?
          kind = stmt.name.to_s.delete_prefix("skip_")
          list = stmt.name.to_s.start_with?("skip_") ? decl[:skips] : decl[:filters]
          args.each { |a| list << Filter.new(kind, Rieles.literal(a).to_s, only, except) }
        when :layout
          decl[:layout] = Rieles.literal(args.first)
          decl[:layout] = decl[:layout].to_s if decl[:layout]
        when :http_basic_authenticate_with
          # A generated before filter comparing the Authorization header.
          filter = "rieles_basic_auth_#{decl[:extra].size}"
          only = kw[:only] && Array(Rieles.literal(kw[:only])).map(&:to_s)
          except = kw[:except] && Array(Rieles.literal(kw[:except])).map(&:to_s)
          user, password = kw[:name], kw[:password]
          raise CompileError, "#{file}:#{stmt.location.start_line}: http_basic_authenticate_with needs name: and password:" unless user && password
          decl[:filters] << Filter.new("before_action", filter, only, except)
          decl[:arities][filter] = 0
          decl[:extra] << "  def #{filter}\n    return if Rieles.basic_auth?(@req, (#{user.slice}).to_s, (#{password.slice}).to_s)\n" \
                          "    @res.headers[\"WWW-Authenticate\"] = \"Basic realm=\\\"Application\\\"\"\n" \
                          "    render_plain(\"HTTP Basic: Access denied.\\n\", 401)\n  end\n"
        when :skip_forgery_protection then decl[:forgery] = false
        when :protect_from_forgery then decl[:forgery] = true
        when :rescue_from
          handler = kw[:with] or raise CompileError, "#{file}:#{stmt.location.start_line}: rescue_from needs with: :method"
          args.each { |a| decl[:rescues] << RescueHandler.new(a.slice, Rieles.literal(handler).to_s) }
        end
      end
      decl
    end

    def app_controller = @controllers.fetch("ApplicationController")

    def forgery_protection?(name)
      own = name == "ApplicationController" ? nil : @controllers[name][:forgery]
      own.nil? ? app_controller[:forgery] != false : own
    end

    def filters_for(name, action, kind)
      own = name == "ApplicationController" ? nil : @controllers[name]
      chain = app_controller[:filters] + (own ? own[:filters] : [])
      skips = own ? own[:skips] : []
      chain.select do |f|
        f.kind == kind && f.applies?(action) &&
          skips.none? { |s| s.kind == kind && s.name == f.name && s.applies?(action) }
      end
    end

    # Before filters run first, so what they assign counts for the action.
    def assigns_for(name, action)
      controller = @controllers[name]
      assigned = controller[:ctx].assigns[action].to_a
      filters_for(name, action, "before_action").each do |f|
        owner = controller[:arities].key?(f.name) ? controller : app_controller
        assigned |= owner[:ctx].assigns[f.name].to_a
      end
      assigned
    end

    # Later declarations win, the controller's before ApplicationController's.
    def rescues_for(name)
      own = name == "ApplicationController" ? [] : @controllers[name][:rescues]
      (own.reverse + app_controller[:rescues].reverse).map do |r|
        owner = @controllers[name][:arities].key?(r.handler) ? @controllers[name] : app_controller
        arity = owner[:arities][r.handler] or raise CompileError, "#{owner[:file]}: rescue_from handler #{r.handler} is not defined"
        [r.exception, arity.zero? ? r.handler : "#{r.handler}(e)"]
      end
    end

    # Every template an action renders must find each exposure assigned in
    # that action; otherwise the template would read nil.
    def check_responses(controllers)
      controllers.each do |name, c|
        c[:ctx].responses.each do |action, responses|
          responses.each do |r|
            next unless r.template
            missing = @templates[r.template].exposures - assigns_for(name, action)
            next if missing.empty?
            raise CompileError, "#{r.where}: #{r.template} reads #{missing.map { |m| "@#{m}" }.join(', ')}, " \
                                "which #{name}##{action} doesn't assign"
          end
        end
      end
    end

    # The template an action renders when it doesn't render or redirect,
    # or nil when its exposures aren't all assigned (then it must respond).
    def implicit_template(controller, action)
      t = @templates["#{controller[:dir]}/#{action}"]
      return nil unless t&.page?
      name = @controllers.key(controller)
      missing = t.exposures - assigns_for(name, action)
      return t if missing.empty?
      return nil if controller[:ctx].responses[action].any?
      raise CompileError, "#{controller[:file]}: #{t.key} reads #{missing.map { |m| "@#{m}" }.join(', ')}, " \
                          "which ##{action} doesn't assign"
    end

    # `layout "x"`, `layout false`, or layouts/<controller>.html.erb.
    def layout_override(name, controller)
      return nil if name == "ApplicationController"
      declared = controller.fetch(:layout, :none)
      layout = if declared == false then false
               elsif declared != :none then @templates["layouts/#{declared}"] || raise(CompileError, "#{controller[:file]}: no app/views/layouts/#{declared}.html.erb")
               else @templates["layouts/#{controller[:dir]}"]
               end
      return nil if layout.nil?
      html = layout ? "ApplicationView.new(self).#{layout.method_name}(html)" : "html"
      "  def render_view(html, status)\n    render_html(#{html}, status)\n  end"
    end

    def render_methods(name, controller)
      used = controller[:ctx].responses.values.flatten.map(&:template).compact
      used += controller[:actions].filter_map { |a| implicit_template(controller, a)&.key }
      override = layout_override(name, controller)
      return override && "class #{name}\n#{override}\nend\n" if used.empty?
      defs = used.uniq.map do |key|
        t = @templates[key]
        args = t.exposures.map { |n| "@#{n}" }.join(", ")
        "  def #{t.render_method}(status, layout = \"\")\n" \
          "    render_with_layout(ApplicationView.new(self).#{t.method_name}#{args.empty? ? '' : "(#{args})"}, status, layout)\n" \
          "  end"
      end
      "class #{name}\n#{[*defs, override].compact.join("\n\n")}\nend\n"
    end

    def indent_layouts
      @templates.values.select(&:layout?).map do |t|
        "    return render_html(ApplicationView.new(self).#{t.method_name}(html), status) if layout == #{t.name.inspect}"
      end.join("\n")
    end

    def application_controller_support
      layout = @templates["layouts/application"]
      <<~RUBY
        class ApplicationController
          def render_view(html, status)
            render_html(#{layout ? "ApplicationView.new(self).#{layout.method_name}(html)" : 'html'}, status)
          end

          def render_error(status, message)
            render_view("<h1>" + status.to_s + "</h1><p>" + h(message) + "</p>", status)
          end

          # render :show, layout: false | "name"; "" keeps the controller's.
          def render_with_layout(html, status, layout)
            return render_view(html, status) if layout.empty?
            return render_html(html, status) if layout == "none"
        #{indent_layouts}
            render_view(html, status)
          end

        #{path_helpers}
        end
      RUBY
    end

    # HTML forms can only POST; `_method` picks PATCH, PUT or DELETE.
    # /posts/1.json is /posts/1 with format=json, for respond_to.
    def method_override
      <<~RUBY
        before do
          content_type = req.req_headers["content-type"]
          if !content_type.nil? && content_type.include?("application/json") && req.raw_body.length > 0
            Rieles::JsonParams.new(req.raw_body.dup.force_encoding("UTF-8"), req.params).parse
          end
          if req.path.end_with?(".json")
            req.path = req.path.delete_suffix(".json")
            req.params["format"] = "json"
          end
          if req.verb == "POST"
            override = Tep.param(req, "_method").upcase
            req.verb = override if override == "PATCH" || override == "PUT" || override == "DELETE"
          end
        end
      RUBY
    end

    def runner_class
      return "" unless @script
      body = Lowering.lower(@script, "runner", Context.new(self, "", view: false))
      "#{SOURCE_MARK}runner\nclass RielesRunner\n  def self.run\n#{body.gsub(/^(?=.)/, '    ')}\n  end\nend\n"
    end

    def seeds_class
      file = path("db/seeds.rb")
      return "" unless File.exist?(file)
      body = Lowering.lower(File.read(file), rel(file), Context.new(self, "", view: false))
      "#{SOURCE_MARK}db/seeds.rb\nclass RielesSeeds\n  def self.run\n#{body.gsub(/^(?=.)/, '    ')}\n  end\nend\n"
    end

    def migrations = @migrations ||= Migrations.new(path("db/migrate"))

    # app/jobs: ApplicationJob, each job class, and the dispatcher the
    # worker calls by name (spinel can't look classes up at runtime).
    # app/mailers: ApplicationMailer (default from:) and mailers whose
    # actions end in mail(to:, subject:), rendering <mailer>/<action>.text.erb
    # and/or .html.erb with the action's ivars.
    def mailers_source
      files = Dir[path("app/mailers/*.rb")].sort
      base = files.find { |f| f.end_with?("/application_mailer.rb") }
      parts = []
      from = nil
      if base
        klass = Rieles.parse(File.read(base), rel(base)).statements.body.find { |n| n.is_a?(Prism::ClassNode) }
        (klass&.body&.body || []).each do |stmt|
          next unless stmt.is_a?(Prism::CallNode) && stmt.name == :default
          _, kw = Rieles.call_args(stmt)
          from = kw[:from] && Rieles.literal(kw[:from]).to_s
        end
      end
      parts << "class ApplicationMailer < Rieles::Mailer\n#{from ? "  def default_from = #{from.inspect}\n" : ''}end\n"
      (files - [base]).each do |file|
        dir = File.basename(file, ".rb")
        ctx = Context.new(self, dir, view: false, mailer: true)
        parts << "#{SOURCE_MARK}#{rel(file)}\n" + Lowering.lower(File.read(file), rel(file), ctx)
      end
      parts.join("\n")
    end

    def jobs_source
      files = Dir[path("app/jobs/*.rb")].sort
      base = files.find { |f| f.end_with?("/application_job.rb") }
      jobs = files - [base]
      parts = [base ? File.read(base).sub(/<\s*(ActiveJob::Base|Rieles::Job)/, "< Rieles::Job") : "class ApplicationJob < Rieles::Job\nend\n"]
      names = jobs.map do |file|
        klass = Rieles.parse(File.read(file), rel(file)).statements.body.find { |n| n.is_a?(Prism::ClassNode) } or
          raise CompileError, "#{rel(file)}: expected a job class"
        parts << "#{SOURCE_MARK}#{rel(file)}\n" + Lowering.lower(File.read(file), rel(file), Context.new(self, "", view: false, job: true))
        klass.constant_path.slice
      end
      branches = names.map { |n| "  return #{n}.new.perform(arg) if name == #{n.inspect}" }
      branches << '  return Rieles::Mail.from_json(arg).deliver_now.to if name == "Rieles::Mail"' 
      parts << "module RielesJobs\n  def self.dispatch(name, arg)\n#{branches.map { |b| "  #{b}" }.join("\n")}\n" \
               "    raise ArgumentError, \"unknown job \" + name\n  end\nend\n"
      parts.join("\n")
    end

    # test/models/*_test.rb: class PostTest < Rieles::ModelTest (or
    # ActiveSupport::TestCase) with test_* methods.
    def model_tests
      @model_tests ||= Dir[path("test/models/**/*_test.rb")].sort.map do |file|
        source = File.read(file)
        klass = Rieles.parse(source, rel(file)).statements.body.find { |n| n.is_a?(Prism::ClassNode) } or
          raise CompileError, "#{rel(file)}: expected a test class"
        name = klass.constant_path.slice
        tests = (klass.body&.body || []).grep(Prism::DefNode).map(&:name).map(&:to_s).select { |n| n.start_with?("test_") }
        header = klass.location.slice.lines.first
        source = source.sub(header, "class #{name} < Rieles::ModelTest\n")
        { file: rel(file), name: name, tests: tests,
          source: Lowering.lower(source, rel(file), Context.new(self, "", view: false, test: true)) }
      end
    end

    # RIELES_RUN_TESTS=1 runs every model test and exits with its status.
    def test_runner
      cases = model_tests.flat_map do |t|
        t[:tests].map do |m|
          "    runner.run_case(#{"#{t[:name]}##{m}".inspect}) do\n" \
            "      test = #{t[:name]}.new\n      test.setup\n      test.#{m}\n      test.teardown\n    end"
        end
      end
      "  if ENV.fetch(\"RIELES_RUN_TESTS\", \"\") == \"1\"\n    runner = Rieles::TestRunner.new\n" \
        "#{cases.join("\n")}\n    exit(runner.finish)\n  end\n"
    end

    # RIELES_ROLLBACK=1 undoes the latest applied migration and exits.
    def rollback_code
      branches = migrations.migrations.reverse.map do |m|
        action = m.down ? "Rieles.unapply(#{m.version.inspect}, #{m.name.inspect}, #{m.down.inspect})" : "Rieles.irreversible(#{m.version.inspect}, #{m.name.inspect})"
        "elsif latest == #{m.version.inspect}\n      #{action}"
      end
      ['  if ENV.fetch("RIELES_ROLLBACK", "") == "1"',
       "    latest = Rieles.latest_migration",
       '    if latest.empty?',
       '      puts "rieles: nothing to roll back"',
       *branches.map { |b| "    #{b}" },
       "    end",
       "    exit(0)",
       "  end"]
    end

    # With db/migrate, pending migrations run at boot; without it, tables
    # and added columns come from db/schema.rb.
    # Digested asset names change with their content, so they can be cached for good.
    def asset_cache_headers
      return "" if asset_digests.empty?
      <<~RUBY
        after do
          if RielesAssets::DIGESTS.values.include?(req.path)
            res.headers["Cache-Control"] = "public, max-age=31536000, immutable"
          end
        end
      RUBY
    end

    def schema_setup(schema)
      statements = if migrations.any?
                     ['  db.exec("CREATE TABLE IF NOT EXISTS schema_migrations (version TEXT PRIMARY KEY)")'] +
                       rollback_code +
                       migrations.migrations.map { |m| "  Rieles.migrate(#{m.version.inspect}, #{m.name.inspect}, #{m.statements.inspect})" } +
                       ['  exit(0) if ENV.fetch("RIELES_MIGRATE", "") == "1"']
                   else
                     schema.tables.values.flat_map do |t|
                       cols = t.columns.reject { |c| c.name == "id" }
                       ["  db.exec(#{t.create_sql.inspect})",
                        "  Rieles.add_missing_columns(#{t.name.inspect}, #{cols.map(&:name).inspect}, #{cols.map { |c| t.add_column_sql(c) }.inspect})"]
                     end + schema.indexes.map { |i| "  db.exec(#{Schema.index_sql(i).inspect})" }
                   end
      seeds = File.exist?(path("db/seeds.rb"))
      <<~RUBY
        on_start do
          if Rieles.env == "production" && ENV.fetch("SECRET_KEY_BASE", "").empty?
            $stderr.puts "rieles: set SECRET_KEY_BASE in production"
            exit(1)
          end
          db = Rieles.db
        #{statements.join("\n")}
          boot_sql = ENV.fetch("RIELES_BOOT_SQL", "")
          Rieles.run_sql_file(boot_sql) unless boot_sql.empty?
        #{seeds ? "  if ENV.fetch(\"RIELES_SEED\", \"\") == \"1\"\n    RielesSeeds.run\n    puts \"rieles: seeded\"\n    exit(0)\n  end" : ""}
        #{@tests ? test_runner : ''}
          Rieles.work_jobs if ENV.fetch("RIELES_JOBS", "") == "1"
        #{@script ? "  RielesRunner.run\n    exit(0)" : ''}
          Rieles::DB.close
        end
      RUBY
    end

    def action_route_block(route)
      action = @actions[route.action] or
        raise CompileError, "config/routes.rb: no app/actions/#{route.action.tr('.', '/')}.rb for #{Rieles.class_name(route.action, "Actions")}"
      dispatch(route, action.class_name, "ApplicationController", "handle(@req, @res)", Rieles.class_name(route.action, "Actions"),
               "render_error(500, \"#{action.class_name} didn't respond\") unless performed?")
    end

    def route_block(route, controllers)
      return action_route_block(route) unless route.controller
      klass = "#{Inflector.camelize(route.controller)}Controller"
      controller = controllers[klass] or raise CompileError, "config/routes.rb: no #{klass} for #{route.path}"
      unless controller[:actions].include?(route.action)
        raise CompileError, "config/routes.rb: #{klass}##{route.action} is not defined"
      end
      template = implicit_template(controller, route.action)
      implicit = if template
                   "#{template.render_method}(200) unless performed?"
                 else
                   "render_error(500, \"No template for #{route.controller}/#{route.action}\") unless performed?"
                 end
      display = "#{route.controller.split('/').map { |s| Inflector.camelize(s) }.join('::')}Controller"
      dispatch(route, klass, klass, route.action, "#{display}##{route.action}", implicit)
    end

    # The chain runs inside the controller, where private filters and
    # handlers are callable (spinel enforces visibility).
    def dispatch(route, klass, controller, call, label, fallback)
      action = call.sub(/\(.*/, "")
      runner = "rieles_#{route.verb}_#{route.path.gsub(/[^a-z0-9]+/i, '_')}"
      befores = filters_for(controller, action, "before_action").map(&:name)
      afters = filters_for(controller, action, "after_action").map(&:name)
      steps = befores.each_with_index.map { |f, i| i.zero? ? f : "#{f} unless performed?" }
      body = [call, fallback, *afters]
      body = ["unless performed?", *body.map { |l| "  #{l}" }, "end"] if befores.any?
      if forgery_protection?(controller)
        steps.unshift("if Rieles.forgery_protection? && !verified_request?",
                      "  render_error(422, \"Invalid authenticity token\")", "  return", "end")
      end
      rescues = rescues_for(controller)
      handler_defs = rescues.each_with_index.map do |(_, handler), i|
        "def #{runner}_rescue#{i}(e)\n  #{handler}\n  render_error(500, \"Something went wrong\") unless performed?\nend"
      end
      handlers = rescues.each_with_index.map do |(exception, _), i|
        "rescue #{exception} => e\n  Rieles.log.error(e)\n  c.#{runner}_rescue#{i}(e)"
      end
      <<~RUBY
        class #{klass}
          def #{runner}
        #{(steps + body).map { |l| "    #{l}" }.join("\n")}
          end

        #{handler_defs.join("\n\n").gsub(/^(?=.)/, "  ")}
        end

        #{route.verb} #{route.regex ? "%r{#{route.regex}}" : route.path.inspect} do
        #{(route.captures || []).each_with_index.map { |c, i| "  req.params[#{c.inspect}] = req.params.fetch(#{(i + 1).to_s.inspect}, \"\")" }.join("\n")}
          request_id = Rieles.request_id(req)
          res.headers["X-Request-Id"] = request_id
          Rieles.set_locale("")
          Rieles.log.start(req.verb, req.path, #{label.inspect}, request_id, req.params)
          c = #{klass}.new(req, res)
          begin
            c.#{runner}
        #{handlers.join("\n").gsub(/^(?=.)/, "  ")}
          rescue Rieles::RecordNotFound => e
            Rieles.log.error(e)
            c.render_error(404, "Not found")
          rescue Rieles::ParameterMissing => e
            Rieles.log.error(e)
            c.render_error(400, e.message)
          rescue Rieles::RecordInvalid => e
            Rieles.log.error(e)
            c.render_error(422, e.message)
          rescue StandardError => e
            Rieles.log.error(e)
            c.render_error(500, Rieles.env == "development" ? e.class.name + ": " + e.message : "Something went wrong")
          end
          Rieles.log.finish(res.status)
          c.response_body
        end
      RUBY
    end

    def not_found_block
      <<~RUBY
        not_found do
          request_id = Rieles.request_id(req)
          res.headers["X-Request-Id"] = request_id
          Rieles.log.start(req.verb, req.path, "", request_id, req.params)
          c = ApplicationController.new(req, res)
          c.render_error(404, "Not found")
          Rieles.log.finish(res.status)
          c.response_body
        end
      RUBY
    end
  end
end
