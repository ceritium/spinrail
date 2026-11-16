require "set"
require "securerandom"
require "active_support"
require "active_support/values/time_zone"

module Spinrail
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
      def turbo_stream? = name.end_with?(".turbo_stream")
      def svg? = name.end_with?(".svg")

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
    SOURCE_MARK = "# spinrail:source ".freeze

    Filter = Struct.new(:kind, :name, :only, :except) do
      def applies?(action) = (only.nil? || only.include?(action)) && !except&.include?(action)
    end

    RescueHandler = Struct.new(:exception, :handler)

    # What the lowering records and resolves for one file.
    class Context
      attr_reader :dir, :exposures, :assigns, :responses

      def initialize(build, dir, view:, ivars: true, action: nil, controller: false, test: false, job: false, mailer: false, relation: false, model: nil)
        @build = build
        @mailer = mailer
        @relation = relation
        @model = model
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
      def relation? = @relation
      def model_name = @model
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
          raise CompileError, "#{where}: no app/views/#{key.tr('.', '/')}.rb for #{Spinrail.class_name(key, "Views")}"
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

      def path_helper?(name) = !@build.nil? && @build.routes.helpers.key?(name)
      def associations_of(model) = @build ? @build.associations.fetch(model, []) : []
      def warn(message) = @build&.warnings&.push(message)
      def current_def = @current
      def layout?(name) = @build.templates.key?("layouts/#{name}")
      def model?(name) = !@build.nil? && @build.model_names.include?(name)
    end

    attr_reader :templates, :action_views

    def model_names
      @model_names ||= record_files.map { |f| model_name(f) }
    end

    # app/models holds records and plain classes (no superclass), as in Rails.
    def record_files = @record_files ||= model_files.select { |f| model_kind(f) == :record }
    def plain_model_files = model_files.select { |f| model_kind(f) == :plain }
    def current_files = model_files.select { |f| model_kind(f) == :current }
    def model_files
      Dir[path("app/models/**/*.rb")].sort.reject do |f|
        f.end_with?("/application_record.rb") || rel(f).start_with?("app/models/concerns/")
      end
    end

    # app/models/rooms/open.rb holds Rooms::Open.
    def model_name(file) = Inflector.camelize(rel(file).delete_prefix("app/models/").delete_suffix(".rb"))

    # The record model a subclass inherits from (single-table inheritance), or nil.
    def sti_base(file)
      klass = Spinrail.parse(File.read(file), rel(file)).statements.body.find { |n| n.is_a?(Prism::ClassNode) }
      parent = klass&.superclass&.slice
      parent if parent && record_files.any? { |f| model_name(f) == parent }
    end

    # Bases first: a subclass needs its parent defined.
    def models_source(schema)
      children = record_files.filter_map do |f|
        base = sti_base(f) or next
        raise CompileError, "#{rel(f)}: #{model_name(f)} inherits from #{base}, itself a subclass" if sti_base(record_files.find { |b| model_name(b) == base })
        Model.new(f, schema, sti_base: base, build: self)
      end
      bases = record_files.reject { |f| sti_base(f) }.map do |f|
        model = Model.new(f, schema, build: self)
        model.sti_children = children.select { |c| c.sti_base == model.name }
        [f, model]
      end
      rich = bases.any? { |_, m| m.rich_texts.any? } ? [rich_text_model(schema)] : []
      storage = bases.any? { |_, m| m.attachments.any? } ? [active_storage_models(schema)] : []
      rich + storage + bases.map { |f, m| "#{SOURCE_MARK}generated #{rel(f)}\n#{m.to_ruby}" } +
        children.map { |c| "#{SOURCE_MARK}generated #{rel(c.file)}\n#{c.to_ruby}" }
    end

    RICH_TEXT = <<~'RUBY'
      class ActionText::RichText < ApplicationRecord
        def self.find_for(record_type, record_id, name)
          found = record_id > 0 ? where(record_type: record_type, record_id: record_id, name: name).first : nil
          found.nil? ? new(name: name, record_type: record_type, record_id: record_id, body: "") : found
        end

        def to_s = body.to_s
        def to_html = "<div class=\"lexxy-content\">" + Spinrail::Html.sanitize(body.to_s) + "</div>"
        def to_plain_text = Spinrail::Html.to_plain_text(body.to_s)
        def blank? = to_plain_text.empty? && !body.to_s.include?("<action-text-attachment")
        def present? = !blank?
      end
    RUBY

    def rich_text_model(schema)
      model = Model.new("action_text/rich_text.rb", schema, build: self, source: RICH_TEXT, table: "action_text_rich_texts")
      "#{SOURCE_MARK}generated ActionText::RichText\nmodule ActionText\nend\n\n#{model.to_ruby}"
    end

    def active_storage_models(schema)
      ActiveStorage.source(schema) do |source, table, file|
        "#{SOURCE_MARK}generated #{file}\n" + Model.new(file, schema, build: self, source: source, table: table).to_ruby
      end
    end

    def attachments?
      @attachments ||= model_files.any? { |f| File.read(f).match?(/^\s*has_(one|many)_attached\b/) }
    end

    # has_rich_text names: a view printing `x.<name>` renders it sanitized.
    def rich_text_names
      @rich_text_names ||= model_files.flat_map { |f| File.read(f).scan(/^\s*has_rich_text\s+:(\w+)/).flatten }.uniq
    end

    def model_kind(file)
      klass = Spinrail.parse(File.read(file), rel(file)).statements.body.find { |n| n.is_a?(Prism::ClassNode) }
      return :record unless klass
      return :current if Current.current?(klass)
      klass.superclass.nil? ? :plain : :record
    end

    def mailer_names = Dir[path("app/mailers/*.rb")].map { |f| Inflector.camelize(File.basename(f, ".rb")) }
    def fixture_tables = Dir[path("test/fixtures/*.yml")].map { |f| File.basename(f, ".yml") }

    # Non-fatal findings (possible N+1 queries), printed by the CLI.
    def warnings = @warnings ||= []

    # Model name => association names, read from the class bodies.
    def associations
      @associations ||= model_files.to_h do |file|
        names = []
        visit = lambda do |node|
          if node.is_a?(Prism::CallNode) && node.receiver.nil? && %i[has_many has_one belongs_to].include?(node.name)
            arg = node.arguments&.arguments&.first
            names << arg.unescaped if arg.is_a?(Prism::SymbolNode)
          end
          node.compact_child_nodes.each { |c| visit.call(c) }
        end
        visit.call(Spinrail.parse(File.read(file), rel(file)))
        [model_name(file), names]
      end
      # A subclass has its base's associations too.
      record_files.each { |f| (base = sti_base(f)) && @associations[model_name(f)].concat(@associations.fetch(base, [])) }
      @associations
    end

    # tests: compile test/models/*_test.rb in (the test binary).
    # script: Ruby source to run instead of serving (spinrail runner).
    # threads: work jobs on spinel threads (spinrail jobs -c N).
    def initialize(app_dir, tests: false, script: nil, threads: false)
      @app = File.expand_path(app_dir)
      Inflector.load_app(@app)
      @partial_locals = {}
      @tests = tests
      @script = script
      @threads = threads
    end

    def routes = @routes ||= Routes.new(path("config/routes.rb"))

    def write(out_dir)
      FileUtils.rm_rf(out_dir)
      FileUtils.mkdir_p(out_dir)
      @public_dir = File.join(out_dir, "public") if binary_assets.any?
      FileUtils.cp_r("#{path('public')}/.", @public_dir) if @public_dir && Dir.exist?(path("public"))
      asset_files.each do |name, file|
        [name, asset_digests[name].delete_prefix("/")].each do |served|
          target = binary_assets.include?(name) ? File.join(@public_dir, served) : File.join(out_dir, "assets", served)
          FileUtils.mkdir_p(File.dirname(target))
          FileUtils.cp(file, target)
        end
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
      @templates = Dir[path("app/views/**/*.{html,text,turbo_stream,svg}.erb")].to_h do |file|
        key = rel(file).delete_prefix("app/views/").delete_suffix(".erb").delete_suffix(".html")
        [key, Template.new(file, File.dirname(key), File.basename(key), [])]
      end
      @action_views = load_action_views
      views = compile_views
      controllers = load_controllers
      check_responses(controllers)
      @actions = load_actions

      [
        "# Generated by spinrail from #{File.basename(@app)}. Do not edit.",
        "require 'sinatra'",
        # Rails apps get SecureRandom and Base64 without asking (Active Support loads them).
        'require "securerandom"',
        'require "base64"',
        *(attachments? ? ['require "digest"', 'require "fileutils"'] : []),
        # Time.now and Time.current in config.time_zone; the database keeps UTC.
        "ENV[\"TZ\"] = #{time_zone.inspect}",
        # The default prefork server ignores SIGINT while a keep-alive
        # connection is idle (OriPekelman/tep#277).
        *(ENV.fetch("SPINRAIL_SERVER", "scheduled") == "prefork" ? [] : ["set :scheduler, :scheduled"]),
        "Tep.session_secret = ENV.fetch(\"SECRET_KEY_BASE\", #{local_secret.inspect})",
        *(public_dir ? ["set :public_dir, #{public_dir.inspect}"] : []),
        *(postgres? ? ['require "tep/pg"'] : []),
        Gems.for_app(@app).source,
        runtime_source,
        translations,
        assets_source,
        application_record,
        *models_source(schema),
        *current_files.map { |f| "#{SOURCE_MARK}generated #{rel(f)}\n#{Current.new(f, rel(f), self).to_ruby}" },
        *(current_files.empty? ? ["module Spinrail\n  def self.reset_current = nil\nend\n"] : []),
        *plain_model_files.map { |f| "#{SOURCE_MARK}#{rel(f)}\n" + Lowering.lower(File.read(f), rel(f), Context.new(self, "", view: false)) },
        views,
        mailers_source,
        jobs_source,
        cable? ? channels_source : "module Spinrail\n  module Cable\n    def self.subscribe_channel(name, connection, identifier, fd) = false\n  end\nend\n",
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
        *(attachments? ? [ActiveStorage::ROUTE] : []),
        *(cable? ? ["get \"/cable\" do\n  Spinrail::Cable.upgrade(req, res, #{connection_class}.new(req))\nend\n"] : []),
        *routes.routes.map { |r| route_block(r, controllers) },
        not_found_block
      ].join("\n").gsub(/__PARTIAL_LOCALS__(.+?)__/) do
        locals = @partial_locals.fetch(Regexp.last_match(1), [])
        locals.empty? ? "" : "(#{locals.join(', ')})"
      end
    end

    # Turbo Streams over WebSocket, served at /cable when the app uses them.
    def cable?
      Dir[path("app/**/*.{rb,erb}")].any? { |f| File.read(f).match?(/\b(turbo_stream_from|broadcast_\w+_to)\b/) }
    end

    def connection_file = path("app/channels/application_cable/connection.rb")
    def connection_class = File.exist?(connection_file) ? "ApplicationCable::Connection" : "Spinrail::CableConnection"

    # app/channels: ApplicationCable::Connection (identified_by names
    # become accessors that channels delegate to), ApplicationCable::Channel,
    # each channel, and the dispatcher subscriptions go through by name
    # (spinel can't look classes up at runtime).
    def channels_source
      base_file = path("app/channels/application_cable/channel.rb")
      parts = []
      identities = []
      if File.exist?(connection_file)
        source = File.read(connection_file).gsub(/^([ \t]*)identified_by[ \t]+(.+)$/) do
          indent, names = Regexp.last_match.captures
          identities.concat(names.scan(/:(\w+)/).flatten)
          "#{indent}attr_accessor #{names}"
        end
        connection = source.sub("ActionCable::Connection::Base", "Spinrail::CableConnection")
        parts << "#{SOURCE_MARK}#{rel(connection_file)}\n" + lower_channel(connection, connection_file)
      end
      base = File.exist?(base_file) ? File.read(base_file) : "module ApplicationCable\n  class Channel < ActionCable::Channel::Base\n  end\nend\n"
      parts << "#{SOURCE_MARK}#{rel(base_file)}\n" + lower_channel(base.sub("ActionCable::Channel::Base", "Spinrail::CableChannel"), base_file)
      unless identities.empty?
        parts << "module ApplicationCable\n  class Channel\n#{identities.map { |i| "    def #{i} = connection.#{i}\n" }.join}  end\nend\n"
      end
      files = Dir[path("app/channels/**/*.rb")].sort.reject { |f| f.include?("/application_cable/") || f.include?("/concerns/") }
      names = files.map do |file|
        klass = Spinrail.parse(File.read(file), rel(file)).statements.body.find { |n| n.is_a?(Prism::ClassNode) } or
          raise CompileError, "#{rel(file)}: expected a channel class"
        parts << "#{SOURCE_MARK}#{rel(file)}\n" + lower_channel(File.read(file), file)
        klass.constant_path.slice
      end
      branches = names.map do |n|
        <<~RUBY.gsub(/^/, "      ")
          if name == #{n.inspect}
            channel = #{n}.new(identifier)
            channel.connection = connection
            channel.subscribed
            return false if channel.rejected?
            channel.streams.each { |stream| Cable.subscribe(fd, identifier, stream) }
            return true
          end
        RUBY
      end
      parts << "module Spinrail\n  module Cable\n    def self.subscribe_channel(name, connection, identifier, fd)\n" \
               "#{branches.join}      false\n    end\n  end\nend\n"
      parts.join("\n")
    end

    def lower_channel(source, file) = Lowering.lower(source, rel(file), Context.new(self, "", view: false))

    # SPINRAIL_DATABASE=postgres (at build time) swaps Tep::SQLite for the
    # PG adapter and reads DATABASE_URL instead of DATABASE_PATH.
    def postgres? = ENV.fetch("SPINRAIL_DATABASE", "sqlite") == "postgres"

    def runtime_source
      source = %w[html.rb jobs.rb].reduce(File.read(RUNTIME)) { |s, f| s + "\n" + File.read(File.join(File.dirname(RUNTIME), f)) }
      source = threaded(source) if @threads
      return source unless postgres?
      source.sub("@conn = Tep::SQLite.new", "@conn = Spinrail::PgConnection.new")
            .sub('raise StatementInvalid, "failed: " + sql if rc < 0', 'raise StatementInvalid, "failed: " + sql + ": " + db.last_error if rc < 0')
            .sub('ENV.fetch("DATABASE_PATH", "./db/development.sqlite3")', 'ENV.fetch("DATABASE_URL", "postgres:///spinrail_development")') +
        "\n" + File.read(File.join(File.dirname(RUNTIME), "postgres.rb"))
    end

    def threaded(source)
      source.sub("def self.db = DB.connection", "def self.db = DBS[Spinrail.db_slot].connection")
            .sub("  def self.synchronize\n    yield\n  end",
                 "  def self.synchronize\n    LOCK.lock\n    begin\n      yield\n    ensure\n      LOCK.unlock\n    end\n  end") +
        "\n" + File.read(File.join(File.dirname(RUNTIME), "threads.rb"))
    end

    # style.css -> /style-<sha256 prefix>.css: a new name whenever the
    # content changes, so browsers can cache assets for good.
    # As in Propshaft, each app/assets subdirectory is a load path of its own.
    def asset_roots
      [path("app/assets"), *Dir[path("app/assets/*/")].sort.map { |d| d.chomp("/") },
       path("app/javascript"), path("vendor/javascript")]
    end

    # Logical name => file; the first load path wins.
    def asset_files
      @asset_files ||= asset_roots.each_with_index.with_object({}) do |(root, i), files|
        pattern = i.zero? ? "#{root}/*" : "#{root}/**/*"
        Dir[pattern].select { |f| File.file?(f) }.sort.each { |file| files[file.delete_prefix("#{root}/")] ||= file }
      end
    end

    # tep embeds assets as C strings, which end at the first NUL; these go on disk instead.
    def binary_assets
      @binary_assets ||= asset_files.select { |_, file| File.binread(file).include?("\0") }.keys.to_set
    end

    def public_dir
      @public_dir || (Dir.exist?(path("public")) ? "public" : nil)
    end

    def asset_digests
      @asset_digests ||= asset_files.sort.to_h do |name, file|
        ext = File.extname(name)
        [name, "/#{name.delete_suffix(ext)}-#{Digest::SHA256.file(file).hexdigest[0, 12]}#{ext}"]
      end
    end

    def assets_source
      entries = asset_digests.map { |k, v| "    #{k.inspect} => #{v.inspect}" }
      entries = ['    "" => ""'] if entries.empty?
      stylesheets = asset_files.keys.select { |name| name.end_with?(".css") }.sort
      "module SpinrailAssets\n  DIGESTS = {\n#{entries.join(",\n")}\n  }.freeze\n" \
        "  STYLESHEETS = #{(stylesheets.empty? ? [""] : stylesheets).inspect}.freeze\n" \
        "  IMPORTMAP = #{importmap_tags.inspect}\nend\n"
    end

    # config/importmap.rb resolved at build time to the importmap script and preload links.
    def importmap_tags
      file = path("config/importmap.rb")
      return "" unless File.exist?(file)
      pins = Importmap.new(@app, asset_files).load(file)
      pins.each_key { |name| raise CompileError, "config/importmap.rb: no asset for pin #{name}" unless asset_digests[pins[name]] }
      imports = pins.to_h { |name, asset| [name, asset_digests[asset]] }
      script = %(<script type="importmap" data-turbo-track="reload">#{JSON.pretty_generate({ "imports" => imports })}</script>)
      ([script] + imports.values.uniq.map { |href| %(<link rel="modulepreload" href="#{href}">) }).join("\n")
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
      "module SpinrailTranslations\n  ALL = {\n#{entries}\n  }.freeze\n  LOCALES = #{locales.inspect}.freeze\nend\n"
    end

    SETTINGS = %w[time_zone].freeze

    # config/application.rb: Spinrail.application.configure do config.x = literal end.
    def settings
      @settings ||= begin
        file = path("config/application.rb")
        found = {}
        if File.exist?(file)
          walk = lambda do |node|
            if node.is_a?(Prism::CallNode) && node.name.end_with?("=") && node.receiver.is_a?(Prism::CallNode) &&
               node.receiver.name == :config && node.receiver.receiver.nil?
              name = node.name.to_s.chomp("=")
              line = "config/application.rb:#{node.location.start_line}"
              raise CompileError, "#{line}: config.#{name} is not supported (#{SETTINGS.join(', ')} are)" unless SETTINGS.include?(name)
              found[name] = Spinrail.literal(node.arguments.arguments.first)
            end
            node.compact_child_nodes.each { |child| walk.call(child) }
          end
          walk.call(Spinrail.parse(File.read(file), file))
        end
        found
      end
    end

    # config.time_zone takes an IANA name or Rails' friendly one ("Madrid",
    # "Eastern Time (US & Canada)"), mapped through ActiveSupport's table.
    def time_zone
      zone = settings.fetch("time_zone", "UTC").to_s
      zone = ActiveSupport::TimeZone::MAPPING.fetch(zone, zone) unless zone == "UTC"
      zoneinfo = "/usr/share/zoneinfo"
      if zone != "UTC" && File.directory?(zoneinfo) && !File.file?(File.join(zoneinfo, zone))
        raise CompileError, "config/application.rb: unknown time zone #{zone.inspect}; use an IANA name such as \"Europe/Madrid\""
      end
      zone
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
      File.exist?(file) ? File.read(file) : "class ApplicationRecord < Spinrail::Record\nend\n"
    end

    def path_helpers
      (attachments? ? ActiveStorage::HELPERS.gsub(/^(?=.)/, "  ") + "\n" : "") + routes.helpers.flat_map do |name, (params, expr, defaults)|
        defaults ||= {}
        sig = params.empty? ? "" : "(#{params.map { |p| defaults.key?(p) ? "#{p} = #{defaults[p].inspect}" : p }.join(', ')})"
        call = params.empty? ? "" : "(#{params.join(', ')})"
        url = name.sub(/_path\z/, "_url")
        ["  def #{name}#{sig}\n    #{expr}\n  end",
         "  def #{url}#{sig}\n    request_base_url + #{name}#{call}\n  end"]
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
        visit.call(Spinrail.parse(source, "helpers"))
        found
      end.uniq
    end

    def compile_views
      raw = raw_helpers
      methods = @templates.values.map do |t|
        signature = t.layout? ? "#{t.method_name}(content)" : "#{t.method_name}__SIGNATURE__"
        # A partial's trailing newline would double up inside loops.
        source = t.partial? ? File.read(t.path).chomp : File.read(t.path)
        ruby = Erb.compile(source, signature, layout: t.layout?, raw: raw, escape: !t.text?, rich: rich_text_names,
                                              log_as: t.partial? ? nil : rel(t.path).delete_prefix("app/views/"))
        ctx = Context.new(self, t.dir, view: true, ivars: t.page?)
        ctx.i18n_scope = "#{t.dir.tr('/', '.')}.#{t.name.delete_prefix('_').delete_suffix('.text')}"
        lowered = Lowering.lower(ruby, rel(t.path), ctx)
        t.exposures = ctx.exposures.keys.sort
        [t, lowered]
      end
      defs = methods.map do |t, ruby|
        # A partial's locals are known once controllers and actions are read
        # too (turbo_stream.append(..., locals:)); generate fills them in.
        signature = if t.partial? && t.strict then "(#{t.strict})"
                    elsif t.partial? then "__PARTIAL_LOCALS__#{t.key}__"
                    else t.exposures.empty? ? "" : "(#{t.exposures.map { |n| "iv_#{n}" }.join(', ')})"
                    end
        "#{SOURCE_MARK}erb #{rel(t.path)}\n" + ruby.sub("__SIGNATURE__", signature)
      end
      defs += @action_views.values.map do |v|
        signature = "#{v.method_name}(#{v.exposures.join(', ')})"
        ruby = Erb.compile(File.read(v.template_path), signature, raw: raw, rich: rich_text_names, log_as: rel(v.template_path).delete_prefix("app/"))
        derived = v.computed.map { |n, body| "  #{n} = begin\n#{body.gsub(/^\s*/, '    ')}\n  end\n" }.join
        ruby = ruby.sub(/\A(def [^\n]*\n)/) { "#{$1}#{derived}" }
        ctx = Context.new(self, File.dirname(v.key.tr(".", "/")), view: true, ivars: false)
        "#{SOURCE_MARK}erb #{rel(v.template_path)}\n" + Lowering.lower(ruby, rel(v.template_path), ctx)
      end
      defs += @action_views.values.flat_map(&:methods).map do |source|
        Lowering.lower(source, "app/views", Context.new(self, "application", view: true, ivars: false)) + "\n"
      end
      <<~RUBY
        #{SOURCE_MARK}generated app/views
        class ApplicationView < Spinrail::View
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
        mod = Spinrail.parse(File.read(file), rel(file)).statements.body.find { |n| n.is_a?(Prism::ModuleNode) }
        raise CompileError, "#{rel(file)}: expected a module" unless mod
        body = (mod.body&.body || []).map { |stmt| stmt.slice.gsub(/^ {#{stmt.location.start_column}}/, "") }.join("\n\n")
        Lowering.lower(body, rel(file), Context.new(self, "application", view: true, ivars: false))
      end.join("\n\n")
    end

    # Actions::Stats::Show / Views::Stats::Show -> "stats.show"
    def namespaced_class(file, namespace)
      klass = Spinrail.parse(File.read(file), rel(file)).statements.body.find { |n| n.is_a?(Prism::ClassNode) }
      name = klass&.constant_path&.slice.to_s
      key = Spinrail.class_key(name, namespace)
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
          names = Spinrail.call_args(stmt).first.map { |a| Spinrail.literal(a).to_s }
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
      "  def params_valid?\n    @params_errors = Spinrail::Errors.new(\"\")\n#{checks.map { |c| "    #{c}" }.join("\n")}\n" \
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
        key = Spinrail.literal(rule.receiver.arguments.arguments.first).to_s
        full = prefix.empty? ? key : "#{prefix}[#{key}]"
        label = key.inspect
        required = rule.receiver.name == :required
        if rule.name == :hash && rule.block
          nested = params_rules(rule.block, full, file).map { |l| "#{l} if params.prefixed?(#{full.inspect})" }
          next ["@params_errors.add(#{label}, \"is missing\") unless params.prefixed?(#{full.inspect})"] + nested if required
          next nested
        end
        type = rule.arguments ? Spinrail.literal(rule.arguments.arguments.first) : :string
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
        source = expand_concerns(File.read(file), rel(file))
        klass = Spinrail.parse(source, rel(file)).statements.body.find { |n| n.is_a?(Prism::ClassNode) }
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
          klass = Spinrail.parse(source, rel(file)).statements.body.find { |n| n.is_a?(Prism::ClassNode) }
        end
        ctx = Context.new(self, dir, view: false, controller: true)
        lowered = Lowering.lower(source, rel(file), ctx)
        decl = controller_declarations(klass, rel(file))
        lowered = lowered.sub(/\nend\s*\z/, "\n#{decl[:extra].join("\n")}end\n") unless decl[:extra].empty?
        controllers[name] = decl.merge(dir: dir, source: lowered, ctx: ctx, file: rel(file))
      end
      controllers["ApplicationController"] ||= {
        dir: "application", actions: [], filters: [], skips: [], rescues: [], arities: {}, forgery: nil, extra: [],
        source: "class ApplicationController < Spinrail::Controller\nend\n",
        ctx: Context.new(self, "application", view: false, controller: true), file: "app/controllers/application_controller.rb"
      }
      @controllers = controllers
    end

    # A controller concern is pasted where it is included: its included
    # block runs in place, as in Rails, so callback order is kept.
    def expand_concerns(source, file)
      klass = Spinrail.parse(source, file).statements.body.find { |n| n.is_a?(Prism::ClassNode) }
      includes = (klass&.body&.body || []).select do |stmt|
        stmt.is_a?(Prism::CallNode) && stmt.receiver.nil? && stmt.name == :include && stmt.arguments&.arguments&.size == 1 &&
          File.exist?(concern_path(stmt.arguments.arguments.first.slice))
      end
      includes.reverse_each do |stmt|
        name = stmt.arguments.arguments.first.slice
        concern_file = rel(concern_path(name))
        mod = Spinrail.parse(File.read(concern_path(name)), concern_file).statements.body.find { |n| n.is_a?(Prism::ModuleNode) }
        raise CompileError, "#{concern_file}: expected module #{name}" unless mod&.constant_path&.slice == name
        body = (mod.body&.body || []).flat_map do |s|
          next [] if s.is_a?(Prism::CallNode) && s.name == :extend && s.arguments&.slice == "ActiveSupport::Concern"
          if s.is_a?(Prism::CallNode) && s.receiver.nil? && s.name == :included && s.block
            next (s.block.body&.body || []).map(&:slice)
          end
          if s.is_a?(Prism::CallNode) && s.receiver.nil? && %i[class_methods include].include?(s.name)
            raise CompileError, "#{concern_file}:#{s.location.start_line}: #{s.name} is not supported in a controller concern"
          end
          [s.slice]
        end
        loc = stmt.location
        source = source.byteslice(0, loc.start_offset) + (body + ["public"]).join("\n\n") + source.byteslice(loc.end_offset..)
      end
      source
    end

    def concern_path(name) = path("app/controllers/concerns/#{Inflector.underscore(name)}.rb")

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
        args, kw = Spinrail.call_args(stmt)
        case stmt.name
        when :private, :protected
          visible = false if args.empty?
          args.each do |a|
            if a.is_a?(Prism::DefNode)
              decl[:arities][a.name.to_s] = a.parameters&.requireds&.size.to_i
            else
              decl[:actions].delete(Spinrail.literal(a).to_s)
            end
          end
        when :public
          visible = true if args.empty?
        when :before_action, :after_action, :skip_before_action, :skip_after_action
          only = kw[:only] && Array(Spinrail.literal(kw[:only])).map(&:to_s)
          except = kw[:except] && Array(Spinrail.literal(kw[:except])).map(&:to_s)
          unknown = kw.keys - %i[only except]
          raise CompileError, "#{file}:#{stmt.location.start_line}: unsupported option #{unknown.first}" if unknown.any?
          kind = stmt.name.to_s.delete_prefix("skip_")
          list = stmt.name.to_s.start_with?("skip_") ? decl[:skips] : decl[:filters]
          args.each { |a| list << Filter.new(kind, Spinrail.literal(a).to_s, only, except) }
        when :layout
          decl[:layout] = Spinrail.literal(args.first)
          decl[:layout] = decl[:layout].to_s if decl[:layout]
        when :http_basic_authenticate_with
          # A generated before filter comparing the Authorization header.
          filter = "spinrail_basic_auth_#{decl[:extra].size}"
          only = kw[:only] && Array(Spinrail.literal(kw[:only])).map(&:to_s)
          except = kw[:except] && Array(Spinrail.literal(kw[:except])).map(&:to_s)
          user, password = kw[:name], kw[:password]
          raise CompileError, "#{file}:#{stmt.location.start_line}: http_basic_authenticate_with needs name: and password:" unless user && password
          decl[:filters] << Filter.new("before_action", filter, only, except)
          decl[:arities][filter] = 0
          decl[:extra] << "  def #{filter}\n    return if Spinrail.basic_auth?(@req, (#{user.slice}).to_s, (#{password.slice}).to_s)\n" \
                          "    @res.headers[\"WWW-Authenticate\"] = \"Basic realm=\\\"Application\\\"\"\n" \
                          "    render_plain(\"HTTP Basic: Access denied.\\n\", 401)\n  end\n"
        when :skip_forgery_protection then decl[:forgery] = false
        when :protect_from_forgery then decl[:forgery] = true
        when :rescue_from
          handler = kw[:with] or raise CompileError, "#{file}:#{stmt.location.start_line}: rescue_from needs with: :method"
          args.each { |a| decl[:rescues] << RescueHandler.new(a.slice, Spinrail.literal(handler).to_s) }
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
               elsif declared != :none
                 @templates["layouts/#{declared}"] || raise(CompileError, "#{controller[:file]}: no app/views/layouts/#{declared}.html.erb")
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
        html = "ApplicationView.new(self).#{t.method_name}#{args.empty? ? '' : "(#{args})"}"
        body = if t.turbo_stream? then "render_turbo_stream(#{html}, status)"
               elsif t.svg? then "render_svg(#{html}, status)"
               else "render_with_layout(#{html}, status, layout)"
               end
        "  def #{t.render_method}(status, layout = \"\")\n    #{body}\n  end"
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
            Spinrail::JsonParams.new(req.raw_body.dup.force_encoding("UTF-8"), req.params).parse
          end
          qmark = req.raw_path.index("?")
          Spinrail.index_array_params(req.raw_path[qmark + 1, req.raw_path.length - qmark - 1], req.params) unless qmark.nil?
          Spinrail.index_array_params(req.raw_body, req.params) if req.form?
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
      "#{SOURCE_MARK}runner\nclass SpinrailRunner\n  def self.run\n#{body.gsub(/^(?=.)/, '    ')}\n  end\nend\n"
    end

    def seeds_class
      file = path("db/seeds.rb")
      return "" unless File.exist?(file)
      body = Lowering.lower(File.read(file), rel(file), Context.new(self, "", view: false))
      "#{SOURCE_MARK}db/seeds.rb\nclass SpinrailSeeds\n  def self.run\n#{body.gsub(/^(?=.)/, '    ')}\n  end\nend\n"
    end

    def migrations = @migrations ||= Migrations.new(path("db/migrate"))

    # Jobs, recurring tasks or mailers (deliver_later) need the queue tables.
    def jobs?
      Dir[path("app/jobs/*.rb")].any? { |f| !f.end_with?("/application_job.rb") } ||
        Dir[path("app/mailers/*.rb")].any? ||
        Recurring.new(path("config/recurring.yml")).tasks.any?
    end

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
        klass = Spinrail.parse(File.read(base), rel(base)).statements.body.find { |n| n.is_a?(Prism::ClassNode) }
        (klass&.body&.body || []).each do |stmt|
          next unless stmt.is_a?(Prism::CallNode) && stmt.name == :default
          _, kw = Spinrail.call_args(stmt)
          from = kw[:from] && Spinrail.literal(kw[:from]).to_s
        end
      end
      parts << "class ApplicationMailer < Spinrail::Mailer\n#{from ? "  def default_from = #{from.inspect}\n" : ''}end\n"
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
      parts = [base ? lower_job(File.read(base).sub(/<\s*(ActiveJob::Base|Spinrail::Job)/, "< Spinrail::Job"), base) : "class ApplicationJob < Spinrail::Job\nend\n"]
      defaults = base ? job_options(base).slice(:queue, :priority) : {}
      inherited = base ? job_options(base).fetch(:handlers, []) : []
      specs = jobs.map do |file|
        parts << lower_job(File.read(file), file)
        spec = defaults.merge(job_options(file))
        # Like rescue_from, the last declared wins; the job's own before ApplicationJob's.
        spec.merge(handlers: spec.fetch(:handlers, []).reverse + inherited.reverse)
      end
      recurring = Recurring.new(path("config/recurring.yml"))
      recurring.tasks.each do |t|
        next unless t.job && specs.none? { |j| j[:name] == t.job }
        raise CompileError, "config/recurring.yml: #{t.key}: no app/jobs class #{t.job}"
      end
      parts << lower_job(recurring.to_ruby, path("config/recurring.yml"))
      dispatch = specs.map { |j| "    return #{perform_call(j)} if name == #{j[:name].inspect}" } + recurring.dispatch
      queues = specs.filter_map { |j| "    return #{j[:queue].inspect} if name == #{j[:name].inspect}" if j[:queue] }
      priorities = specs.filter_map { |j| "    return #{j[:priority]} if name == #{j[:name].inspect}" if j[:priority] }
      limited = specs.select { |j| j[:concurrency] }
      by_job = ->(field) { limited.map { |j| "    return #{j[:concurrency][field]} if name == #{j[:name].inspect}" }.join("\n") }
      parts << <<~RUBY
        module SpinrailJobs
          def self.dispatch(name, args)
            Spinrail.reset_current
        #{dispatch.join("\n")}
            return Spinrail::Mail.from_json(Spinrail::Jobs.arg(args, 0)).deliver_now.to if name == "Spinrail::Mail"
            raise ArgumentError, "unknown job " + name
          end

          # Seconds to wait before retrying, or Spinrail::Jobs::FAIL / DISCARD.
          def self.retry_wait(name, error, executions)
        #{specs.select { |j| j[:handlers].any? }.map { |j| retry_branch(j) }.join("\n")}
            Spinrail::Jobs::FAIL
          end

          # limits_concurrency: the key ("" for none), slots, seconds a
          # semaphore lasts, and whether a job over the limit is dropped.
          def self.concurrency_key(name, args)
        #{by_job.(:key)}
            ""
          end

          def self.concurrency_limit(name)
        #{by_job.(:to)}
            1
          end

          def self.concurrency_duration(name)
        #{by_job.(:duration)}
            180
          end

          def self.concurrency_discard(name)
        #{by_job.(:discard)}
            false
          end

          def self.queue_for(name)
        #{queues.join("\n")}
            #{(defaults[:queue] || "default").inspect}
          end

          def self.priority_for(name)
        #{priorities.join("\n")}
            #{defaults[:priority] || 0}
          end
        end
      RUBY
      parts.join("\n")
    end

    def lower_job(source, file) = "#{SOURCE_MARK}#{rel(file)}\n" + Lowering.lower(source, rel(file), Context.new(self, "", view: false, job: true))

    # queue_as, queue_with_priority and perform's arity, read at build time
    # since spinel can't dispatch on a class looked up by name.
    def job_options(file)
      classes = Spinrail.parse(File.read(file), rel(file)).statements.body.grep(Prism::ClassNode)
      klass = classes.find { |c| c.constant_path.slice.end_with?("Job") } or
        raise CompileError, "#{rel(file)}: expected a job class"
      spec = { name: klass.constant_path.slice }
      (klass.body&.body || []).each do |stmt|
        if stmt.is_a?(Prism::CallNode) && stmt.receiver.nil? && stmt.name == :limits_concurrency
          spec[:concurrency] = concurrency(stmt, spec[:name], file)
        elsif stmt.is_a?(Prism::CallNode) && stmt.receiver.nil? && %i[retry_on discard_on].include?(stmt.name)
          (spec[:handlers] ||= []) << job_handler(stmt, file)
        elsif stmt.is_a?(Prism::CallNode) && stmt.receiver.nil? && %i[queue_as queue_with_priority].include?(stmt.name)
          value = stmt.arguments&.arguments&.first
          literal = value && Spinrail.literal(value)
          raise CompileError, "#{rel(file)}: #{stmt.name} takes a literal" if literal.nil?
          stmt.name == :queue_as ? spec[:queue] = literal.to_s : spec[:priority] = Integer(literal)
        elsif stmt.is_a?(Prism::DefNode) && stmt.name == :perform && stmt.receiver.nil?
          params = stmt.parameters
          if params&.rest || params&.keywords&.any? || params&.keyword_rest
            raise CompileError, "#{rel(file)}: perform takes positional arguments only"
          end
          spec[:required] = params ? params.requireds.size : 0
          spec[:optional] = params ? params.optionals.size : 0
        end
      end
      spec
    end

    # limits_concurrency to: 1, key: ->(account_id) { ... }, duration: 3.minutes,
    # group: "name", on_conflict: :block | :discard. The key lambda gets the
    # job's arguments (Strings) and is lowered like app code.
    def concurrency(stmt, job, file)
      _, kw = Spinrail.call_args(stmt)
      unknown = kw.keys - %i[to key duration group on_conflict]
      raise CompileError, "#{rel(file)}: limits_concurrency doesn't take #{unknown.join(', ')}" if unknown.any?
      key = kw[:key] or raise CompileError, "#{rel(file)}: limits_concurrency needs key:"
      group = kw[:group] ? "(#{kw[:group].slice}).to_s" : job.inspect
      value = if key.is_a?(Prism::LambdaNode)
                n = key.parameters&.parameters&.requireds&.size || 0
                lambda = Lowering.lower(key.slice, rel(file), Context.new(self, "", view: false, job: true))
                "(#{lambda}).call(#{(0...n).map { |i| "Spinrail::Jobs.arg(args, #{i})" }.join(', ')}).to_s"
              else
                "(#{key.slice}).to_s"
              end
      on_conflict = kw[:on_conflict] && Spinrail.literal(kw[:on_conflict])
      raise CompileError, "#{rel(file)}: on_conflict is :block or :discard" unless [nil, :block, :discard].include?(on_conflict)
      { key: "#{group} + \"/\" + #{value}", to: kw[:to] ? "(#{kw[:to].slice}).to_i" : "1",
        duration: kw[:duration] ? "(#{kw[:duration].slice}).to_i" : "180", discard: (on_conflict == :discard).to_s }
    end

    # retry_on Errors, wait: 3, attempts: 5 (Active Job's defaults);
    # wait: :polynomially_longer or a lambda of executions. jitter: is ignored.
    def job_handler(stmt, file)
      args, kw = Spinrail.call_args(stmt)
      raise CompileError, "#{rel(file)}: #{stmt.name} with a block isn't supported" if stmt.block
      raise CompileError, "#{rel(file)}: #{stmt.name} needs an error class" if args.empty?
      unknown = kw.keys - (stmt.name == :retry_on ? %i[wait attempts jitter] : [])
      raise CompileError, "#{rel(file)}: #{stmt.name} doesn't take #{unknown.join(', ')}" if unknown.any?
      errors = args.map(&:slice)
      return { errors:, wait: "Spinrail::Jobs::DISCARD", attempts: nil } if stmt.name == :discard_on
      wait = kw[:wait]
      wait = if wait.nil? then "3"
             elsif wait.is_a?(Prism::SymbolNode) && %i[polynomially_longer exponentially_longer].include?(wait.unescaped.to_sym)
               "executions * executions * executions * executions + 2"
             elsif wait.is_a?(Prism::LambdaNode) then "(#{wait.slice}).call(executions).to_i"
             else "(#{wait.slice}).to_i"
             end
      attempts = kw[:attempts]
      attempts = if attempts.nil? then "5"
                 elsif attempts.is_a?(Prism::SymbolNode) && attempts.unescaped == "unlimited" then nil
                 else attempts.slice
                 end
      { errors:, wait:, attempts: }
    end

    def retry_branch(job)
      checks = job[:handlers].map do |h|
        wait = h[:attempts] ? "executions < #{h[:attempts]} ? #{h[:wait]} : Spinrail::Jobs::FAIL" : h[:wait]
        "      return #{wait} if #{h[:errors].map { |e| "error.is_a?(#{e})" }.join(' || ')}"
      end
      "    if name == #{job[:name].inspect}\n#{checks.join("\n")}\n    end"
    end

    # perform(a, b = "x"): args[1] only when the job was enqueued with it.
    def perform_call(job)
      required = job.fetch(:required, 1)
      optional = job.fetch(:optional, 0)
      call = ->(n) { "#{job[:name]}.new.perform(#{(0...n).map { |i| "Spinrail::Jobs.arg(args, #{i})" }.join(', ')})" }
      (required...(required + optional)).reverse_each.reduce(call.(required + optional)) do |code, n|
        "(args.length > #{n} ? #{code} : #{call.(n)})"
      end
    end

    # test/models/*_test.rb: class PostTest < Spinrail::ModelTest (or
    # ActiveSupport::TestCase) with test_* methods.
    def model_tests
      @model_tests ||= Dir[path("test/models/**/*_test.rb")].sort.map do |file|
        source = File.read(file)
        klass = Spinrail.parse(source, rel(file)).statements.body.find { |n| n.is_a?(Prism::ClassNode) } or
          raise CompileError, "#{rel(file)}: expected a test class"
        name = klass.constant_path.slice
        tests = (klass.body&.body || []).grep(Prism::DefNode).map(&:name).map(&:to_s).select { |n| n.start_with?("test_") }
        header = klass.location.slice.lines.first
        source = source.sub(header, "class #{name} < Spinrail::ModelTest\n")
        { file: rel(file), name: name, tests: tests,
          source: Lowering.lower(source, rel(file), Context.new(self, "", view: false, test: true)) }
      end
    end

    # SPINRAIL_RUN_TESTS=1 runs every model test and exits with its status.
    def test_runner
      cases = model_tests.flat_map do |t|
        t[:tests].map do |m|
          "    runner.run_case(#{"#{t[:name]}##{m}".inspect}) do\n" \
            "      test = #{t[:name]}.new\n      test.setup\n      test.#{m}\n      test.teardown\n    end"
        end
      end
      "  if ENV.fetch(\"SPINRAIL_RUN_TESTS\", \"\") == \"1\"\n    runner = Spinrail::TestRunner.new\n" \
        "#{cases.join("\n")}\n    exit(runner.finish)\n  end\n"
    end

    # SPINRAIL_ROLLBACK=1 undoes the latest applied migration and exits.
    def rollback_code
      branches = migrations.migrations.reverse.map do |m|
        migration = "#{m.version.inspect}, #{m.name.inspect}"
        action = m.down ? "Spinrail.unapply(#{migration}, #{m.down.inspect})" : "Spinrail.irreversible(#{migration})"
        "elsif latest == #{m.version.inspect}\n      #{action}"
      end
      ['  if ENV.fetch("SPINRAIL_ROLLBACK", "") == "1"',
       "    latest = Spinrail.latest_migration",
       "    if latest.empty?",
       '      puts "spinrail: nothing to roll back"',
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
          if SpinrailAssets::DIGESTS.values.include?(req.path)
            res.headers["Cache-Control"] = "public, max-age=31536000, immutable"
          end
        end
      RUBY
    end

    def schema_setup(schema)
      statements = if migrations.any?
                     ['  db.exec("CREATE TABLE IF NOT EXISTS schema_migrations (version TEXT PRIMARY KEY)")'] +
                       rollback_code +
                       migrations.migrations.map { |m| "  Spinrail.migrate(#{m.version.inspect}, #{m.name.inspect}, #{m.statements.inspect})" } +
                       ['  exit(0) if ENV.fetch("SPINRAIL_MIGRATE", "") == "1"']
                   else
                     schema.tables.values.flat_map do |t|
                       cols = t.columns.reject { |c| c.name == "id" }
                       ["  db.exec(#{t.create_sql.inspect})",
                        "  Spinrail.add_missing_columns(#{t.name.inspect}, #{cols.map(&:name).inspect}, #{cols.map { |c| t.add_column_sql(c) }.inspect})"]
                     end + schema.indexes.map { |i| "  db.exec(#{Schema.index_sql(i).inspect})" } +
                       schema.virtual_tables.map { |sql| "  db.exec(#{sql.inspect})" }
                   end
      seeds = File.exist?(path("db/seeds.rb"))
      # An app with no tables, jobs or seeds never opens the database, so the
      # binary runs anywhere without a writable db/.
      queue = @tests || @threads || seeds || jobs?
      <<~RUBY
        on_start do
          if Spinrail.env == "production" && ENV.fetch("SECRET_KEY_BASE", "").empty?
            $stderr.puts "spinrail: set SECRET_KEY_BASE in production"
            exit(1)
          end
        #{statements.empty? ? "" : "  db = Spinrail.db\n#{statements.join("\n")}"}
        #{queue ? "  Spinrail::Jobs.schema" : '  Spinrail::Jobs.schema unless ENV.fetch("SPINRAIL_JOBS", "").empty?'}
          boot_sql = ENV.fetch("SPINRAIL_BOOT_SQL", "")
          Spinrail.run_sql_file(boot_sql) unless boot_sql.empty?
        #{seeds ? "  if ENV.fetch(\"SPINRAIL_SEED\", \"\") == \"1\"\n    SpinrailSeeds.run\n    puts \"spinrail: seeded\"\n    exit(0)\n  end" : ""}
        #{@tests ? test_runner : ''}
          #{@threads ? 'Spinrail.work_jobs_threaded(ENV.fetch("SPINRAIL_JOB_THREADS", "2").to_i)' : 'Spinrail::Jobs.command(ENV.fetch("SPINRAIL_JOBS", ""))'}
        #{@script ? "  SpinrailRunner.run\n    exit(0)" : ''}
          Spinrail::DB.close
        end
      RUBY
    end

    def action_route_block(route)
      action = @actions[route.action] or
        raise CompileError, "config/routes.rb: no app/actions/#{route.action.tr('.', '/')}.rb for #{Spinrail.class_name(route.action, "Actions")}"
      dispatch(route, action.class_name, "ApplicationController", "handle(@req, @res)", Spinrail.class_name(route.action, "Actions"),
               "render_error(500, \"#{action.class_name} didn't respond\") unless performed?")
    end

    def route_block(route, controllers)
      return action_route_block(route) unless route.controller
      # Rails' health check: 200 once the app boots.
      if route.controller == "rails/health" && route.action == "show"
        return "#{route.verb} #{route.path.inspect} do\n  \"<!DOCTYPE html><html><body style=\\\"background-color: green\\\"></body></html>\"\nend\n"
      end
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
      runner = "spinrail_#{route.verb}_#{route.path.gsub(/[^a-z0-9]+/i, '_')}"
      befores = filters_for(controller, action, "before_action").map(&:name)
      afters = filters_for(controller, action, "after_action").map(&:name)
      steps = befores.each_with_index.map { |f, i| i.zero? ? f : "#{f} unless performed?" }
      body = [call, fallback, *afters]
      body = ["unless performed?", *body.map { |l| "  #{l}" }, "end"] if befores.any?
      if forgery_protection?(controller)
        steps.unshift("if Spinrail.forgery_protection? && !verified_request?",
                      "  render_error(422, \"Invalid authenticity token\")", "  return", "end")
      end
      rescues = rescues_for(controller)
      handler_defs = rescues.each_with_index.map do |(_, handler), i|
        "def #{runner}_rescue#{i}(e)\n  #{handler}\n  render_error(500, \"Something went wrong\") unless performed?\nend"
      end
      handlers = rescues.each_with_index.map do |(exception, _), i|
        "rescue #{exception} => e\n  Spinrail.log.error(e)\n  c.#{runner}_rescue#{i}(e)"
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
          request_id = Spinrail.request_id(req)
          res.headers["X-Request-Id"] = request_id
          Spinrail.set_locale("")
          Spinrail.log.start(req.verb, req.path, #{label.inspect}, request_id, req.params, req.ip)
          c = #{klass}.new(req, res)
          begin
            c.#{runner}
        #{handlers.join("\n").gsub(/^(?=.)/, "  ")}
          rescue Spinrail::RecordNotFound => e
            Spinrail.log.error(e)
            c.render_error(404, "Not found")
          rescue Spinrail::ParameterMissing => e
            Spinrail.log.error(e)
            c.render_error(400, e.message)
          rescue Spinrail::RecordInvalid => e
            Spinrail.log.error(e)
            c.render_error(422, e.message)
          rescue StandardError => e
            Spinrail.log.error(e)
            c.render_error(500, Spinrail.env == "development" ? e.class.name + ": " + e.message : "Something went wrong")
          end
          Spinrail.log.finish(res.status)
          Spinrail.reset_current
          c.response_body
        end
      RUBY
    end

    def not_found_block
      <<~RUBY
        not_found do
          request_id = Spinrail.request_id(req)
          res.headers["X-Request-Id"] = request_id
          Spinrail.log.start(req.verb, req.path, "", request_id, req.params, req.ip)
          c = ApplicationController.new(req, res)
          c.render_error(404, "Not found")
          Spinrail.log.finish(res.status)
          c.response_body
        end
      RUBY
    end
  end
end
