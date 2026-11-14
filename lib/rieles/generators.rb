require "pathname"

module Rieles
  # rieles new / rieles generate model|controller|scaffold.
  class Generators
    TYPES = %w[string text integer float boolean datetime date references].freeze

    Field = Struct.new(:name, :type) do
      def references? = type == "references"
      def column = references? ? "#{name}_id" : name
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

    def new_app
      abort "rieles: #{@app} already exists" if File.exist?(@app)
      name = File.basename(@app)
      lib = Pathname.new(File.expand_path("..", __dir__)).relative_path_from(Pathname.new(File.join(File.expand_path(@app), "bin")))
      write "bin/rieles", <<~RUBY, mode: 0o755
        #!/usr/bin/env ruby
        require_relative #{File.join(lib.to_s, "rieles").inspect}

        Rieles::CLI.new(ARGV, File.expand_path("..", __dir__)).run
      RUBY
      write ".gitignore", "/#{name}\n/*.next\n/tmp/\n/log/\n/db/*.sqlite3\n"
      write "config/routes.rb", "Rieles.routes.draw do\n  root \"home#index\"\nend\n"
      write "db/schema.rb", "Rieles::Schema.define do\nend\n"
      write "app/models/application_record.rb", "class ApplicationRecord < Rieles::Record\nend\n"
      write "app/controllers/application_controller.rb", "class ApplicationController < Rieles::Controller\nend\n"
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
          <link rel="stylesheet" href="/style.css">
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
        class HomeTest < Rieles::IntegrationTest
          def test_home
            get "/"
            assert_response :success
          end
        end
      RUBY
      @out.puts "\nNext: cd #{@app} && bin/rieles server"
    end

    def generate(kind, name, args)
      abort "rieles: generate #{kind} NAME ..." unless name
      case kind
      when "model" then model(name, fields(args))
      when "controller" then controller(name, args)
      when "scaffold" then scaffold(name, fields(args))
      else abort "rieles: generate model|controller|scaffold"
      end
    end

    private

    def fields(args)
      args.map do |arg|
        name, type = arg.split(":", 2)
        type ||= "string"
        abort "rieles: unknown type #{type} (#{TYPES.join(', ')})" unless TYPES.include?(type)
        Field.new(name, type)
      end
    end

    def model(name, fields)
      klass = Inflector.camelize(name)
      table = Inflector.tableize(klass)
      columns = fields.map { |f| "    t.#{f.type} :#{f.name}" } + ["    t.timestamps"]
      insert_before_last_end("db/schema.rb", "  create_table :#{table} do |t|\n#{columns.join("\n")}\n  end\n")
      assocs = fields.select(&:references?).map { |f| "  belongs_to :#{f.name}\n" }.join
      write "app/models/#{Inflector.underscore(klass)}.rb", "class #{klass} < ApplicationRecord\n#{assocs}end\n"
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
          before_action :set_#{single}, only: [:show, :edit, :update, :destroy]

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
      sample = fields.reject(&:references?).to_h { |f| ["#{single}[#{f.column}]", sample_value(f)] }
      write "test/integration/#{plural}_test.rb", <<~RUBY
        class #{Inflector.camelize(plural)}Test < Rieles::IntegrationTest
          def test_index
            get "/#{plural}"
            assert_response :success
          end

          def test_create
            post "/#{plural}", params: #{sample.inspect}
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
      abort "rieles: config/routes.rb has no `Rieles.routes.draw do`" unless source.include?("Rieles.routes.draw do\n")
      File.write(file, source.sub("Rieles.routes.draw do\n", "Rieles.routes.draw do\n  #{line}\n"))
      @out.puts "      route  #{line}"
    end

    def insert_before_last_end(rel, text)
      file = File.join(@app, rel)
      source = File.read(file)
      index = source.rindex(/^end\b/) or abort "rieles: can't find the closing end of #{rel}"
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
