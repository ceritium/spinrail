require "pathname"

module Spinrail
  # spinrail new / spinrail generate model|controller|scaffold.
  class Generators
    TYPES = %w[string text integer bigint float decimal boolean datetime date time references].freeze

    # name:type[!][:index|:uniq]; `!` makes the column null: false, which
    # gives its reader a single type. References are null: false, as in Rails.
    Field = Struct.new(:name, :type, :null, :index) do
      def references? = type == "references"
      def column = references? ? "#{name}_id" : name
      def options = null ? "" : ", null: false"
      def definition = "t.#{type} :#{name}#{options}"
      def add_index(table) = "add_index :#{table}, [:#{column}]#{index == 'uniq' ? ', unique: true' : ''}"
      def input
        case type
        when "text" then "text_area"
        when "integer", "float" then "number_field"
        when "boolean" then "check_box"
        when "date" then "date_field"
        else "text_field"
        end
      end
    end

    def initialize(app, out = $stdout)
      @app = app
      @out = out
    end

    def new_app(git: true, bundle: true)
      abort "spinrail: #{@app} already exists" if File.exist?(@app)
      name = File.basename(@app)
      write "bin/spinrail", <<~RUBY, mode: 0o755
        #!/usr/bin/env ruby
        require "bundler/setup"
        require "spinrail"

        Spinrail::CLI.new(ARGV, File.expand_path("..", __dir__)).run
      RUBY
      write ".gitignore", "/#{name}\n/*.next\n/tmp/\n/log/\n/db/*.sqlite3*\n/.bundle/\n"
      write "Gemfile", <<~RUBY
        source "https://rubygems.org"

        gem "spinrail", github: "ceritium/spinrail", branch: "master"

        group :development do
          gem "rubocop", require: false
        end
      RUBY
      write ".rubocop.yml", <<~YAML
        # Spinel/* flags what spinel won't compile. Tests run on CRuby.
        require:
          - spinrail/rubocop

        AllCops:
          NewCops: enable
          SuggestExtensions: false
          Exclude:
            - "bin/*"
            - "db/schema.rb"
            - "tmp/**/*"
            - "vendor/**/*"

        Spinel:
          Exclude:
            - "test/**/*"

        Style/Documentation:
          Enabled: false

        Style/FrozenStringLiteralComment:
          Enabled: false

        Style/StringLiterals:
          EnforcedStyle: double_quotes

        Style/EmptyMethod:
          EnforcedStyle: expanded
      YAML
      write "config/routes.rb", "Spinrail.routes.draw do\n  root \"home#index\"\nend\n"
      write "db/schema.rb", "Spinrail::Schema.define do\nend\n"
      write "app/models/application_record.rb", "class ApplicationRecord < Spinrail::Record\nend\n"
      write "app/controllers/application_controller.rb", "class ApplicationController < Spinrail::Controller\nend\n"
      write "app/controllers/home_controller.rb", "class HomeController < ApplicationController\n  def index\n  end\nend\n"
      write "app/helpers/application_helper.rb", "module ApplicationHelper\nend\n"
      write "app/views/home/index.html.erb", "<h1>#{Inflector.camelize(name)}</h1>\n<p>Edit app/views/home/index.html.erb.</p>\n"
      write "app/views/layouts/application.html.erb", <<~ERB
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <%= csrf_meta_tags %>
          <title><%= content_for?(:title) ? yield(:title) : #{Inflector.camelize(name).inspect} %></title>
          <%= stylesheet_link_tag "style" %>
        </head>
        <body>
          <% if notice %><p class="notice"><%= notice %></p><% end %>
          <% if alert %><p class="alert"><%= alert %></p><% end %>
          <%= yield %>
        </body>
        </html>
      ERB
      write "app/assets/style.css", "body { font-family: system-ui, sans-serif; max-width: 40rem; margin: 2rem auto; padding: 0 1rem; }\n" \
                                    ".notice { color: #166534; }\n.alert, .error { color: #b91c1c; }\n"
      write "test/integration/home_test.rb", <<~RUBY
        class HomeTest < Spinrail::IntegrationTest
          def test_home
            get "/"
            assert_response :success
          end
        end
      RUBY
      init_git if git
      bundle_install if bundle
      @out.puts "\nNext: cd #{@app} && bin/spinrail server"
    end

    def generate(kind, name, args)
      abort "spinrail: generate #{kind} NAME ..." unless name || kind == "authentication"
      case kind
      when "model" then model(name, fields(args))
      when "controller" then controller(name, args)
      when "scaffold" then scaffold(name, fields(args))
      when "migration" then migration(name, fields(args))
      when "mailer" then mailer(name, args)
      when "authentication" then authentication
      else abort "spinrail: generate model|controller|scaffold|migration|mailer|authentication"
      end
    end

    private

    # Like rails new: a repo of its own, unless the app lands inside one.
    def init_git
      return if system("git", "-C", File.dirname(@app), "rev-parse", "--is-inside-work-tree", out: File::NULL, err: File::NULL)
      @out.puts "         run  git init" if system("git", "init", "--quiet", @app)
    end

    # Generated from a checkout, the app uses that checkout through Bundler's
    # local git override, so the Gemfile stays the one CI resolves.
    def bundle_install
      checkout = File.expand_path("../..", __dir__)
      Dir.chdir(@app) do
        if File.exist?(File.join(checkout, ".git"))
          system("bundle", "config", "set", "--local", "local.spinrail", checkout, out: File::NULL)
          @out.puts "         run  bundle config set --local local.spinrail #{checkout}"
        end
        @out.puts "         run  bundle install"
        system("bundle", "install", "--quiet") or @out.puts "spinrail: bundle install failed; run it in #{@app}"
      end
    end

    def fields(args)
      args.map do |arg|
        name, type, index = arg.split(":", 3)
        type = "string" if type.nil? || type.empty?
        required = type.end_with?("!")
        type = type.delete_suffix("!")
        abort "spinrail: unknown type #{type} (#{TYPES.join(', ')})" unless TYPES.include?(type)
        abort "spinrail: unknown modifier :#{index} (index, uniq)" if index && !%w[index uniq].include?(index)
        Field.new(name, type, !required && type != "references", index)
      end
    end

    def model(name, fields)
      klass = Inflector.camelize(name)
      table = Inflector.tableize(klass)
      if Dir.exist?(File.join(@app, "db/migrate"))
        migration("Create#{Inflector.camelize(table)}", fields)
      else
        columns = fields.map { |f| "    #{f.definition}" } + ["    t.timestamps"]
        indexes = fields.select(&:index).map { |f| "  #{f.add_index(table)}\n" }.join
        insert_before_last_end("db/schema.rb", "  create_table :#{table} do |t|\n#{columns.join("\n")}\n  end\n#{indexes}")
      end
      assocs = fields.select(&:references?).map { |f| "  belongs_to :#{f.name}\n" }.join
      write "app/models/#{Inflector.underscore(klass)}.rb", "class #{klass} < ApplicationRecord\n#{assocs}end\n"
    end

    # AddXToPosts / RemoveXFromPosts / CreatePosts fill in `change`.
    def migration(name, fields)
      klass = Inflector.camelize(Inflector.underscore(name))
      body = case Inflector.underscore(name)
             when /\Aadd_\w+_to_(\w+)\z/
               table = $1
               fields.map { |f| "    add_column :#{table}, :#{f.column}, :#{f.references? ? 'integer' : f.type}#{f.options}" } +
                 fields.select(&:index).map { |f| "    #{f.add_index(table)}" }
             when /\Aremove_\w+_from_(\w+)\z/ then fields.map { |f| "    remove_column :#{$1}, :#{f.column}" }
             when /\Acreate_(\w+)\z/
               cols = fields.map { |f| "      #{f.definition}" } + ["      t.timestamps"]
               ["    create_table :#{$1} do |t|", *cols, "    end", *fields.select(&:index).map { |f| "    #{f.add_index($1)}" }]
             else []
             end
      version = Time.now.strftime("%Y%m%d%H%M%S")
      write "db/migrate/#{version}_#{Inflector.underscore(name)}.rb",
            "class #{klass} < Spinrail::Migration\n  def change\n#{body.join("\n")}#{body.empty? ? '' : "\n"}  end\nend\n"
    end

    # Rails 8's generator, in spinrail terms: User with has_secure_password,
    # a SessionsController, and require_authentication everywhere else.
    def authentication
      model("user", fields(%w[email_address:string! password_digest:string!]))
      user = File.join(@app, "app/models/user.rb")
      File.write(user, "class User < ApplicationRecord\n  has_secure_password\n  validates :email_address, presence: true, uniqueness: true\nend\n")
      add_route("resource :session, only: %i[new create destroy]")
      write "app/controllers/sessions_controller.rb", <<~RUBY
        class SessionsController < ApplicationController
          skip_before_action :require_authentication, only: %i[new create]

          def new
          end

          def create
            user = User.find_by(email_address: params[:email_address])
            if user&.authenticate(params[:password])
              reset_session
              session[:user_id] = user.id
              redirect_to "/", notice: "Signed in."
            else
              redirect_to new_session_path, alert: "Try another email address or password."
            end
          end

          def destroy
            reset_session
            redirect_to new_session_path, notice: "Signed out.", status: :see_other
          end
        end
      RUBY
      write "app/views/sessions/new.html.erb", <<~ERB
        <h1>Sign in</h1>
        <%= form_with url: session_path do |f| %>
          <%= f.label :email_address %>
          <%= f.email_field :email_address, required: true, autofocus: true %>
          <%= f.label :password %>
          <%= f.password_field :password, required: true %>
          <%= f.submit "Sign in" %>
        <% end %>
      ERB
      controller = File.join(@app, "app/controllers/application_controller.rb")
      source = File.read(controller)
      unless source.include?("require_authentication")
        source = source.sub(/^class ApplicationController < Spinrail::Controller\n/) do |line|
          "#{line}  before_action :require_authentication\n"
        end
        source = source.sub(/^end\s*\z/, <<~RUBY)

            private

            def require_authentication
              redirect_to new_session_path unless session[:user_id]
            end
          end
        RUBY
        File.write(controller, source)
        @out.puts "     update  app/controllers/application_controller.rb"
      end
      write "test/fixtures/users.yml", "one:\n  email_address: one@example.com\n  password_digest: <%= password_digest(\"password\") %>\n"
      write "test/integration/sessions_test.rb", <<~RUBY
        class SessionsTest < Spinrail::IntegrationTest
          fixtures :users

          def test_requires_sign_in
            get "/"
            assert_redirected_to "/session/new"
          end

          def test_sign_in_and_out
            post "/session", params: { email_address: "one@example.com", password: "password" }
            assert_redirected_to "/"
            follow_redirect!
            assert_response :success
            delete "/session"
            assert_redirected_to "/session/new"
          end

          def test_wrong_password
            post "/session", params: { email_address: "one@example.com", password: "nope" }
            assert_redirected_to "/session/new"
          end
        end
      RUBY
    end

    def mailer(name, actions)
      klass = "#{Inflector.camelize(name.delete_suffix('Mailer'))}Mailer"
      dir = Inflector.underscore(klass)
      write "app/mailers/application_mailer.rb", "class ApplicationMailer < ActionMailer::Base\n  default from: \"from@example.com\"\nend\n"
      defs = actions.map { |a| "  def #{a}(to)\n    @greeting = \"Hi\"\n    mail(to: to, subject: #{Inflector.humanize(a).inspect})\n  end" }
      write "app/mailers/#{dir}.rb", "class #{klass} < ApplicationMailer\n#{defs.join("\n\n")}#{defs.empty? ? '' : "\n"}end\n"
      actions.each do |a|
        write "app/views/#{dir}/#{a}.text.erb", "<%= @greeting %>,\n\nFind me in app/views/#{dir}/#{a}.text.erb\n"
      end
    end

    def controller(name, actions)
      klass = "#{Inflector.camelize(name)}Controller"
      dir = Inflector.underscore(name)
      defs = actions.map { |a| "  def #{a}\n  end" }.join("\n\n")
      write "app/controllers/#{dir}_controller.rb", "class #{klass} < ApplicationController\n#{defs}#{defs.empty? ? '' : "\n"}end\n"
      actions.each do |a|
        write "app/views/#{dir}/#{a}.html.erb", "<h1>#{klass}##{a}</h1>\n<p>Find me in app/views/#{dir}/#{a}.html.erb</p>\n"
        add_route(%(get "/#{dir}/#{a}", to: "#{dir}##{a}"))
      end
    end

    def scaffold(name, fields)
      klass = Inflector.camelize(Inflector.singularize(name))
      single = Inflector.underscore(klass)
      plural = Inflector.pluralize(single)
      model(single, fields)
      add_route("resources :#{plural}")
      permitted = fields.map { |f| ":#{f.column}" }.join(", ")
      write "app/controllers/#{plural}_controller.rb", <<~RUBY
        class #{Inflector.camelize(plural)}Controller < ApplicationController
          before_action :set_#{single}, only: %i[show edit update destroy]

          def index
            @#{plural} = #{klass}.order(id: :desc)
          end

          def show
          end

          def new
            @#{single} = #{klass}.new
          end

          def edit
          end

          def create
            @#{single} = #{klass}.new(#{single}_params)
            if @#{single}.save
              redirect_to #{single}_path(@#{single}), notice: "#{klass} was successfully created."
            else
              render :new, status: :unprocessable_entity
            end
          end

          def update
            if @#{single}.update(#{single}_params)
              redirect_to #{single}_path(@#{single}), notice: "#{klass} was successfully updated.", status: :see_other
            else
              render :edit, status: :unprocessable_entity
            end
          end

          def destroy
            @#{single}.destroy
            redirect_to #{plural}_path, notice: "#{klass} was successfully destroyed.", status: :see_other
          end

          private

          def set_#{single}
            @#{single} = #{klass}.find(params[:id])
          end

          def #{single}_params
            params.require(:#{single}).permit(#{permitted})
          end
        end
      RUBY
      human = Inflector.humanize(single)
      title = fields.find { |f| %w[string text].include?(f.type) }
      label = title ? "#{single}.#{title.name}" : "\"#{human} #\" + #{single}.id.to_s"
      write "app/views/#{plural}/index.html.erb", <<~ERB
        <% content_for :title, "#{Inflector.humanize(plural)}" %>
        <h1>#{Inflector.humanize(plural)}</h1>
        <ul>
          <% @#{plural}.each do |#{single}| %>
            <li><%= link_to #{label}, #{single}_path(#{single}) %></li>
          <% end %>
        </ul>
        <%= link_to "New #{human.downcase}", new_#{single}_path %>
      ERB
      attrs = fields.map { |f| "<p><strong>#{Inflector.humanize(f.column)}:</strong> <%= @#{single}.#{f.column} %></p>" }.join("\n")
      write "app/views/#{plural}/show.html.erb", <<~ERB
        #{attrs}
        <%= link_to "Edit", edit_#{single}_path(@#{single}) %> |
        <%= link_to "Back", #{plural}_path %>
        <%= button_to "Destroy", #{single}_path(@#{single}), method: :delete %>
      ERB
      inputs = fields.map { |f| "  <div>\n    <%= f.label :#{f.column} %>\n    <%= f.#{f.input} :#{f.column} %>\n  </div>" }.join("\n")
      write "app/views/#{plural}/_form.html.erb", <<~ERB
        <%= form_with model: #{single} do |f| %>
          <% #{single}.errors.full_messages.each do |message| %>
            <p class="error"><%= message %></p>
          <% end %>
        #{inputs}
          <%= f.submit %>
        <% end %>
      ERB
      write "app/views/#{plural}/new.html.erb", "<h1>New #{human.downcase}</h1>\n<%= render \"form\", #{single}: @#{single} %>\n<%= link_to \"Back\", #{plural}_path %>\n"
      write "app/views/#{plural}/edit.html.erb", "<h1>Editing #{human.downcase}</h1>\n<%= render \"form\", #{single}: @#{single} %>\n<%= link_to \"Show\", #{single}_path(@#{single}) %>\n"
      sample = fields.reject(&:references?).map { |f| "#{"#{single}[#{f.column}]".inspect} => #{sample_value(f).inspect}" }
      params = sample.join(", ").size > 80 ? "{\n      #{sample.join(",\n      ")}\n    }" : "{ #{sample.join(", ")} }"
      write "test/integration/#{plural}_test.rb", <<~RUBY
        class #{Inflector.camelize(plural)}Test < Spinrail::IntegrationTest
          def test_index
            get "/#{plural}"
            assert_response :success
          end

          def test_create
            post "/#{plural}", params: #{params}
            assert_response :redirect
            follow_redirect!
            assert_body_includes "#{klass} was successfully created."
          end
        end
      RUBY
    end

    def sample_value(field)
      { "integer" => "1", "float" => "1.5", "boolean" => "1", "date" => "2026-01-01", "datetime" => "2026-01-01 00:00:00" }
        .fetch(field.type, "Sample #{field.name}")
    end

    def add_route(line)
      file = File.join(@app, "config/routes.rb")
      source = File.read(file)
      abort "spinrail: config/routes.rb has no `Spinrail.routes.draw do`" unless source.include?("Spinrail.routes.draw do\n")
      File.write(file, source.sub("Spinrail.routes.draw do\n", "Spinrail.routes.draw do\n  #{line}\n"))
      @out.puts "      route  #{line}"
    end

    def insert_before_last_end(rel, text)
      file = File.join(@app, rel)
      source = File.read(file)
      index = source.rindex(/^end\b/) or abort "spinrail: can't find the closing end of #{rel}"
      File.write(file, source.insert(index, text))
      @out.puts "     update  #{rel}"
    end

    def write(rel, content, mode: nil)
      file = File.join(@app, rel)
      if File.exist?(file)
        @out.puts "       skip  #{rel} (exists)"
        return
      end
      FileUtils.mkdir_p(File.dirname(file))
      File.write(file, content)
      File.chmod(mode, file) if mode
      @out.puts "     create  #{rel}"
    end
  end
end
