require_relative "helper"

class BuildTest < CompilerTest
  def build(files) = Spinrail::Build.new(minimal_app(files)).send(:generate)

  def test_secure_password_validations_can_be_turned_off
    schema = "Spinrail::Schema.define do\n create_table :users do |t|\n t.string :password_digest\n end\nend\n"
    on = build("db/schema.rb" => schema, "app/models/user.rb" => "class User < ApplicationRecord\n has_secure_password\nend\n")
    off = build("db/schema.rb" => schema, "app/models/user.rb" => "class User < ApplicationRecord\n has_secure_password validations: false\nend\n")
    assert_includes on, "@password_digest.to_s.empty?"
    assert_includes off, "def authenticate(plain)"
    refute_includes off, "can't be blank"
  end

  def test_secure_token_authenticate_by_and_destroy_bang
    schema = "Spinrail::Schema.define do\n create_table :users do |t|\n t.string :email_address\n t.string :password_digest\n t.string :token\n end\nend\n"
    ruby = build("db/schema.rb" => schema, "app/models/user.rb" => "class User < ApplicationRecord\n has_secure_password\n has_secure_token\nend\n")
    assert_includes ruby, "@token = SecureRandom.alphanumeric(24) if @token.to_s.empty?"
    assert_includes ruby, "def regenerate_token = update!(token: SecureRandom.alphanumeric(24))"
    assert_includes ruby, "def self.authenticate_by(conditions) = all.authenticate_by(conditions)"
    assert_includes ruby, "record.authenticate(password) ? record : nil"
    assert_includes ruby, "def destroy!"
    error = assert_raises(Spinrail::CompileError) do
      build("db/schema.rb" => schema, "app/models/user.rb" => "class User < ApplicationRecord\n has_secure_token :auth_token\nend\n")
    end
    assert_match(/needs the auth_token column/, error.message)
  end

  def test_records_inspect_like_rails
    schema = "Spinrail::Schema.define do\n create_table :users do |t|\n t.string :name\n t.string :password_digest\n end\nend\n"
    ruby = build("db/schema.rb" => schema, "app/models/user.rb" => "class User < ApplicationRecord\nend\n")
    assert_includes ruby, %("#<User " + "id: " + @id.inspect + ", " + "name: " + @name.inspect + ", " + "password_digest: [FILTERED]" + ">")
  end

  def test_string_enum_with_prefix
    schema = "Spinrail::Schema.define do\n create_table :memberships do |t|\n t.string :involvement, default: \"mentions\"\n end\nend\n"
    model = %(class Membership < ApplicationRecord\n enum :involvement, { nothing: "nothing", mentions: "mentions" }, prefix: :involved_in\nend\n)
    ruby = build("db/schema.rb" => schema, "app/models/membership.rb" => model)
    assert_includes ruby, %(def involved_in_mentions? = @involvement == "mentions")
    assert_includes ruby, %(def self.involved_in_nothing = all.where(involvement: "nothing"))
    assert_includes ruby, %(!@involvement.nil? && !["nothing", "mentions"].include?(@involvement))
  end

  def test_string_enum_names_store_themselves
    schema = "Spinrail::Schema.define do\n create_table :memberships do |t|\n t.string :involvement\n end\nend\n"
    model = %(class Membership < ApplicationRecord\n enum :involvement, { nothing: "n" }\nend\n)
    error = assert_raises(Spinrail::CompileError) { build("db/schema.rb" => schema, "app/models/membership.rb" => model) }
    assert_match(/stores each name as itself/, error.message)
  end

  def test_has_many_through
    schema = <<~RUBY
      Spinrail::Schema.define do
        create_table :rooms do |t|
          t.string :name
        end
        create_table :users do |t|
          t.string :name
        end
        create_table :memberships do |t|
          t.references :room
          t.references :user
        end
      end
    RUBY
    ruby = build(
      "db/schema.rb" => schema,
      "app/models/room.rb" => "class Room < ApplicationRecord\n has_many :memberships\n has_many :users, through: :memberships\nend\n",
      "app/models/user.rb" => "class User < ApplicationRecord\nend\n",
      "app/models/membership.rb" => "class Membership < ApplicationRecord\n belongs_to :room\n belongs_to :user\nend\n"
    )
    assert_includes ruby, %(def users = User.all.where_subquery("id", "SELECT user_id FROM memberships WHERE room_id = ?", @id.to_s))
  end

  def test_plain_classes_in_app_models
    schema = "Spinrail::Schema.define do\n create_table :users do |t|\n t.string :name\n end\nend\n"
    ruby = build("db/schema.rb" => schema, "app/models/user.rb" => "class User < ApplicationRecord\nend\n",
                 "app/models/first_run.rb" => "class FirstRun\n  def self.create!(name) = User.create!(name: name)\nend\n")
    assert_includes ruby, "class FirstRun\n  def self.create!(name) = User.create!(name: name)\nend"
  end

  def test_current_attributes
    schema = "Spinrail::Schema.define do\n create_table :users do |t|\n t.string :name\n end\nend\n"
    current = <<~RUBY
      class Current < ActiveSupport::CurrentAttributes
        attribute :session, :user

        def session=(value)
          super(value)
          self.user = value.user if value
        end

        def greeting(prefix, upcase: false) = prefix + user.name

        delegate :name, to: :user, prefix: true, allow_nil: true
        before_reset :forget
        resets { Spinrail.set_locale("") }

        private

        def forget = nil
      end
    RUBY
    ruby = build("db/schema.rb" => schema, "app/models/user.rb" => "class User < ApplicationRecord\nend\n",
                 "app/models/current.rb" => current)
    assert_includes ruby, "class Current < CurrentAttributes"
    assert_includes ruby, "  def user=(value)\n    @user = value\n  end"
    assert_includes ruby, "def self.user=(value)\n    instance.user = value\n  end"
    assert_includes ruby, "def self.greeting(prefix, upcase: false)\n    instance.greeting(prefix, upcase: upcase)\n  end"
    assert_includes ruby, "fresh = Current.new\n    INSTANCES[Tep::APP.sched_current + 1] = fresh\n    fresh.spinrail_after_reset"
    assert_includes ruby, "def spinrail_before_reset\n    forget\n  end"
    assert_includes ruby, "def spinrail_after_reset\n    Spinrail.set_locale(\"\")\n  end"
    assert_includes ruby, "def user_name\n    user&.name\n  end"
    assert_includes ruby, "def self.user_name\n    instance.user_name\n  end"
    assert_includes ruby, "def self.set(session: nil, user: nil)"
    assert_includes ruby, "    current.user = user unless user.nil?"
    assert_includes ruby, "def self.reset_current = Current.reset"
    refute_includes ruby, "def self.reset_current = nil"
  end

  def test_belongs_to_default
    schema = "Spinrail::Schema.define do\n create_table :users do |t|\n t.string :name\n end\n create_table :rooms do |t|\n t.references :creator, null: false\n end\nend\n"
    room = %(class Room < ApplicationRecord\n belongs_to :creator, class_name: "User", default: -> { Current.user }\nend\n)
    ruby = build("db/schema.rb" => schema, "app/models/user.rb" => "class User < ApplicationRecord\nend\n", "app/models/room.rb" => room)
    assert_includes ruby, "if !persisted? && @creator_id.to_i == 0\n      default_record = (Current.user)\n      @creator_id = default_record.id if default_record\n    end"
  end

  def test_delegate
    schema = "Spinrail::Schema.define do\n create_table :users do |t|\n t.string :name\n end\n create_table :rooms do |t|\n t.references :user\n end\nend\n"
    room = %(class Room < ApplicationRecord\n belongs_to :user\n delegate :name, :name=, to: :user\n delegate :count, to: :class, prefix: :all\nend\n)
    ruby = build("db/schema.rb" => schema, "app/models/user.rb" => "class User < ApplicationRecord\nend\n", "app/models/room.rb" => room)
    assert_includes ruby, "def name\n    user.name\n  end"
    assert_includes ruby, "def name=(value)\n    user.name = value\n  end"
    assert_includes ruby, "def all_count\n    self.class.count\n  end"
    error = assert_raises(Spinrail::CompileError) do
      build("db/schema.rb" => schema, "app/models/user.rb" => "class User < ApplicationRecord\nend\n",
            "app/models/room.rb" => "class Room < ApplicationRecord\n delegate :name, to: :user, private: true\nend\n")
    end
    assert_match(/unsupported delegate option private/, error.message)
  end

  def test_rails_inflections
    schema = "Spinrail::Schema.define do\n create_table :people do |t|\n t.string :name\n end\n create_table :analyses do |t|\n t.references :person\n end\nend\n"
    ruby = build("db/schema.rb" => schema, "app/models/person.rb" => "class Person < ApplicationRecord\n has_many :analyses\nend\n",
                 "app/models/analysis.rb" => "class Analysis < ApplicationRecord\n belongs_to :person\nend\n")
    assert_includes ruby, "FROM people"
    assert_includes ruby, "def analyses\n    relation = Analysis.where(person_id: @id)"
  end

  def test_time_zone_from_config
    assert_includes build({}), %(ENV["TZ"] = "UTC")
    config = %(Spinrail.application.configure do\n config.time_zone = "Europe/Madrid"\nend\n)
    assert_includes build("config/application.rb" => config), %(ENV["TZ"] = "Europe/Madrid")
  end

  def test_unknown_time_zone_or_setting
    zone = %(Spinrail.application.configure do\n config.time_zone = "Madrid"\nend\n)
    error = assert_raises(Spinrail::CompileError) { build("config/application.rb" => zone) }
    assert_match(/unknown time zone "Madrid"/, error.message)
    setting = %(Spinrail.application.configure do\n config.cache_store = :memory_store\nend\n)
    error = assert_raises(Spinrail::CompileError) { build("config/application.rb" => setting) }
    assert_match(/config.cache_store is not supported/, error.message)
  end

  def test_scopes_and_class_methods_run_on_relations
    schema = "Spinrail::Schema.define do\n create_table :users do |t|\n t.string :name\n end\n " \
             "create_table :messages do |t|\n t.references :creator\n t.string :body\n t.timestamps\n end\nend\n"
    model = <<~RUBY
      class Message < ApplicationRecord
        PAGE_SIZE = 40
        belongs_to :creator, class_name: "User"
        scope :ordered, -> { order(:created_at) }
        scope :with_creator, -> { includes(:creator) }
        scope :last_page, -> { ordered.last(PAGE_SIZE) }

        def self.original
          order(:created_at).first
        end

        class << self
          def recent = order(:created_at)

          private

          def helper = 1
        end
      end
    RUBY
    ruby = build("db/schema.rb" => schema, "app/models/user.rb" => "class User < ApplicationRecord\nend\n",
                 "app/models/message.rb" => model)
    relation = ruby[/^class MessageRelation.*?^end$/m]
    assert_includes relation, "PAGE_SIZE = Message::PAGE_SIZE"
    assert_includes relation, %(with_includes(["creator"]))
    assert_includes relation, "ordered.last_n(PAGE_SIZE)"
    assert_match(/def original\n\s*order\(created_at: :asc\)\.first/, relation)
    assert_includes ruby, "def self.find_by!(conditions) = all.find_by!(conditions)"
    assert_includes ruby, "def self.recent = order(created_at: :asc)"
    assert_includes ruby, "def self.helper = 1"
    assert_includes relation, "def recent = order(created_at: :asc)"
    refute_includes relation, "def helper"
  end

  def test_single_table_inheritance
    schema = "Spinrail::Schema.define do\n create_table :rooms do |t|\n t.string :name\n t.string :type, null: false\n end\nend\n"
    files = {
      "db/schema.rb" => schema,
      "app/models/room.rb" => "class Room < ApplicationRecord\n def involvement = \"mentions\"\nend\n",
      "app/models/rooms/open.rb" => "class Rooms::Open < Room\n after_create :grant\n validates :name, presence: true\n\n private\n\n def grant = nil\nend\n",
      "app/models/rooms/direct.rb" => "class Rooms::Direct < Room\n def involvement = \"everything\"\nend\n",
      "app/models/first_run.rb" => "class FirstRun\n def self.go(room) = room.becomes!(Rooms::Direct)\nend\n"
    }
    ruby = build(files)
    assert_operator ruby.index("class Room < ApplicationRecord"), :<, ruby.index("module Rooms\nend\nclass Rooms::Direct < Room")
    assert_includes ruby, %(return Rooms::Open.new(id: db.col_int(0), name: (db.col_null?(1) ? nil : db.col_str(1)), type: db.col_str(2)) if sti_type == "Rooms::Open")
    assert_includes ruby, %(def self.all = RoomRelation.new.where(type: "Rooms::Open"))
    assert_includes ruby, "def sti_after_create\n    grant\n  end"
    assert_match(/def sti_validate\n\s*@errors.add\(:name/, ruby)
    assert_includes ruby, "def sti_after_create = nil"
    assert_includes ruby, %(def becomes_rooms_direct = Rooms::Direct.new(id: @id, name: @name, type: "Rooms::Direct"))
    assert_includes ruby, "room.becomes_rooms_direct"
    error = assert_raises(Spinrail::CompileError) do
      build(files.merge("app/models/rooms/open.rb" => "class Rooms::Open < Room\n has_many :things\nend\n"))
    end
    assert_match(/has_many in a subclass is not supported yet; declare it on Room/, error.message)
  end

  def test_controller_concerns_are_pasted_where_included
    ruby = build(
      "config/routes.rb" => %(Spinrail.routes.draw do\n get "/", to: "posts#index"\n get "/x", to: "posts#visit"\nend\n),
      "app/controllers/concerns/loads_post.rb" => <<~RUBY,
        module LoadsPost
          extend ActiveSupport::Concern

          included do
            before_action :load
          end

          def visit
            @post = "visited"
          end

          private

          def load
            @post = "x"
          end
        end
      RUBY
      "app/controllers/posts_controller.rb" => "class PostsController < ApplicationController\n include LoadsPost\n\n def index\n end\nend\n",
      "app/views/posts/index.html.erb" => "<%= @post %>",
      "app/views/posts/visit.html.erb" => "<%= @post %>"
    )
    assert ruby.include?("    load\n    unless performed?\n      index\n"), "the concern's filter runs"
    refute_includes ruby, "include LoadsPost"
    error = assert_raises(Spinrail::CompileError) do
      build("app/controllers/concerns/loads_post.rb" => "module LoadsPost\n class_methods do\n end\nend\n",
            "app/controllers/posts_controller.rb" => "class PostsController < ApplicationController\n include LoadsPost\nend\n")
    end
    assert_match(/class_methods is not supported/, error.message)
  end

  def test_turbo_stream_templates
    files = {
      "config/routes.rb" => %(Spinrail.routes.draw do\n post "/posts", to: "posts#create"\nend\n),
      "db/schema.rb" => "Spinrail::Schema.define do\n create_table :posts do |t|\n t.string :title\n end\nend\n",
      "app/models/post.rb" => "class Post < ApplicationRecord\nend\n",
      "app/controllers/posts_controller.rb" => <<~RUBY,
        class PostsController < ApplicationController
          def create
            @post = Post.create!(title: "x")
            respond_to do |format|
              format.turbo_stream
              format.html { redirect_to "/" }
            end
          end
        end
      RUBY
      "app/views/posts/_post.html.erb" => "<p><%= post.title %></p>",
      "app/views/posts/create.turbo_stream.erb" =>
        '<%= turbo_stream.append dom_id(@post, :list), partial: "posts/post", locals: { post: @post } %>'
    }
    ruby = build(files)
    assert_includes ruby, "if wants_turbo_stream?\nrender_view_posts_create_turbo_stream(200)"
    assert_includes ruby, "render_turbo_stream(ApplicationView.new(self).view_posts_create_turbo_stream(@post), status)"
    assert_includes ruby, 'turbo_stream_tag("append", ((iv_post).dom_id_with((:list).to_s)).to_s, self.partial_posts_post(iv_post)'
    assert_includes ruby, %(def dom_id_with(prefix) = @id > 0 ? prefix + "_post_" + @id.to_s : prefix + "_post")
    files.delete("app/views/posts/create.turbo_stream.erb")
    error = assert_raises(Spinrail::CompileError) { build(files) }
    assert_match(%r{missing template app/views/posts/create.turbo_stream.erb}, error.message)
  end

  def test_turbo_broadcasts
    files = {
      "config/routes.rb" => %(Spinrail.routes.draw do\n get "/posts/:id", to: "posts#show"\nend\n),
      "db/schema.rb" => "Spinrail::Schema.define do\n create_table :posts do |t|\n t.string :title\n end\n " \
                        "create_table :comments do |t|\n t.references :post\n t.string :body\n end\nend\n",
      "app/models/post.rb" => "class Post < ApplicationRecord\n has_many :comments\nend\n",
      "app/models/comment.rb" => <<~RUBY,
        class Comment < ApplicationRecord
          belongs_to :post
          def broadcast_create = broadcast_append_to(post, :comments, target: [post, :comments])
          def broadcast_gone = broadcast_remove_to(post)
        end
      RUBY
      "app/controllers/posts_controller.rb" => "class PostsController < ApplicationController\n def show\n @post = Post.find(params[:id])\n end\nend\n",
      "app/views/posts/show.html.erb" => "<%= turbo_stream_from @post, :comments %>",
      "app/views/comments/_comment.html.erb" => "<p><%= comment.body %></p>"
    }
    ruby = build(files)
    assert_includes ruby, %(out << (turbo_stream_from_tag((iv_post).to_stream_name + ":" + "comments", "Turbo::StreamsChannel")).to_s)
    assert_includes ruby, 'Spinrail::Cable.broadcast((post).to_stream_name + ":" + "comments", Spinrail::Cable.view.turbo_stream_tag("append", ' \
                          '(post).dom_id_with("comments"), ApplicationView.new(Spinrail::Cable.view).partial_comments_comment(self)))'
    assert_includes ruby, %(Spinrail::Cable.broadcast((post).to_stream_name, Spinrail::Cable.view.turbo_stream_tag("remove", self.dom_id, "")))
    assert_includes ruby, %(def to_stream_name = "posts/" + @id.to_s)
    assert_includes ruby, %(get "/cable" do\n  Spinrail::Cable.upgrade(req, res, Spinrail::CableConnection.new(req)))

    files["app/views/posts/show.html.erb"] = "<%= @post.title %>"
    files["app/models/comment.rb"] = "class Comment < ApplicationRecord\n belongs_to :post\nend\n"
    refute_includes build(files), %(get "/cable")
  end

  def test_cable_channels
    files = {
      "config/routes.rb" => %(Spinrail.routes.draw do\n get "/", to: "posts#index"\nend\n),
      "db/schema.rb" => "Spinrail::Schema.define do\n create_table :posts do |t|\n t.string :title\n end\nend\n",
      "app/models/post.rb" => "class Post < ApplicationRecord\nend\n",
      "app/controllers/posts_controller.rb" => "class PostsController < ApplicationController\n def index\n end\nend\n",
      "app/views/posts/index.html.erb" => %(<%= turbo_stream_from :posts, channel: "PostsChannel" %>),
      "app/channels/application_cable/connection.rb" => <<~RUBY,
        module ApplicationCable
          class Connection < ActionCable::Connection::Base
            identified_by :current_user

            def connect
              self.current_user = cookies.signed[:user] || reject_unauthorized_connection
            end
          end
        end
      RUBY
      "app/channels/posts_channel.rb" => <<~RUBY
        class PostsChannel < ApplicationCable::Channel
          def subscribed
            current_user == "admin" ? stream_from(verified_stream_name_from_params) : reject
          end
        end
      RUBY
    }
    ruby = build(files)
    assert_includes ruby, %(turbo_stream_from_tag("posts", "PostsChannel"))
    assert_includes ruby, "class Connection < Spinrail::CableConnection\n    attr_accessor :current_user"
    assert_includes ruby, %(self.current_user = cookie_get_signed("user") || reject_unauthorized_connection)
    assert_includes ruby, "class Channel < Spinrail::CableChannel"
    assert_includes ruby, "def current_user = connection.current_user"
    assert_includes ruby, %(if name == "PostsChannel"\n        channel = PostsChannel.new(identifier))
    assert_includes ruby, %(Spinrail::Cable.upgrade(req, res, ApplicationCable::Connection.new(req)))
  end

  def test_rails_health_check
    ruby = build("config/routes.rb" => %(Spinrail.routes.draw do\n get "up" => "rails/health#show", as: :rails_health_check\nend\n))
    assert_includes ruby, %(get "/up" do\n  "<!DOCTYPE html><html><body style=\\"background-color: green\\"></body></html>"\nend)
  end

  def test_rich_text
    schema = "Spinrail::Schema.define do\n create_table :posts do |t|\n t.string :title\n end\n " \
             "create_table :action_text_rich_texts do |t|\n t.string :name\n t.text :body\n t.string :record_type\n " \
             "t.integer :record_id\n t.timestamps\n end\nend\n"
    files = {
      "config/routes.rb" => %(Spinrail.routes.draw do\n get "/posts/:id", to: "posts#show"\nend\n),
      "db/schema.rb" => schema,
      "app/models/post.rb" => "class Post < ApplicationRecord\n has_rich_text :content\nend\n",
      "app/controllers/posts_controller.rb" => "class PostsController < ApplicationController\n def show\n @post = Post.find(params[:id])\n end\nend\n",
      "app/views/posts/show.html.erb" => "<%= @post.content %><%= @post.title %>" \
                                         "<%= form_with model: @post, url: \"/posts\" do |f| %><%= f.rich_text_area :content %><% end %>"
    }
    ruby = build(files)
    assert_includes ruby, "class ActionText::RichText < ApplicationRecord"
    assert_includes ruby, %(@rich_content = ActionText::RichText.find_for("Post", @id, "content"))
    assert_match(/def initialize\(id: 0, title: nil, content: nil\)/, ruby)
    assert_includes ruby, %(self.content = params.get("content") if params.has?("content"))
    assert_includes ruby, "out << (iv_post.content).to_html"
    assert_includes ruby, "out << h((iv_post.title).to_s)"
    assert_includes ruby, %(form_rich_textarea("post", "content", (iv_post.content).to_s, ""))

    files["app/models/post.rb"] = "class Post < ApplicationRecord\n has_rich_text :title\nend\n"
    error = assert_raises(Spinrail::CompileError) { build(files) }
    assert_match(/has_rich_text :title clashes with the title column/, error.message)
  end

  def test_template_reading_an_unassigned_ivar
    error = assert_raises(Spinrail::CompileError) do
      build(
        "config/routes.rb" => %(Spinrail.routes.draw do\n get "/", to: "posts#index"\nend\n),
        "app/controllers/posts_controller.rb" => "class PostsController < ApplicationController\n def index\n end\nend\n",
        "app/views/posts/index.html.erb" => "<%= @posts %>"
      )
    end
    assert_match(/reads @posts, which #index doesn't assign/, error.message)
  end

  def test_before_action_assignments_count
    ruby = build(
      "config/routes.rb" => %(Spinrail.routes.draw do\n get "/", to: "posts#index"\nend\n),
      "app/controllers/posts_controller.rb" => <<~RUBY,
        class PostsController < ApplicationController
          before_action :load

          def index
          end

          private

          def load
            @posts = "x"
          end
        end
      RUBY
      "app/views/posts/index.html.erb" => "<%= @posts %>"
    )
    assert ruby.include?("    load\n    unless performed?\n      index\n"), "the filter runs before the action"
  end

  def test_private_methods_are_not_actions
    error = assert_raises(Spinrail::CompileError) do
      build(
        "config/routes.rb" => %(Spinrail.routes.draw do\n get "/", to: "posts#helper"\nend\n),
        "app/controllers/posts_controller.rb" => "class PostsController < ApplicationController\n private\n def helper\n end\nend\n"
      )
    end
    assert_match(/PostsController#helper is not defined/, error.message)
  end

  def test_unknown_partial
    assert_raises(Spinrail::CompileError) do
      build(
        "config/routes.rb" => %(Spinrail.routes.draw do\n get "/", to: "posts#index"\nend\n),
        "app/controllers/posts_controller.rb" => "class PostsController < ApplicationController\n def index\n end\nend\n",
        "app/views/posts/index.html.erb" => %(<%= render "missing" %>)
      )
    end
  end

  def test_strict_locals_are_checked
    files = {
      "config/routes.rb" => %(Spinrail.routes.draw do\n get "/", to: "posts#index"\nend\n),
      "app/controllers/posts_controller.rb" => "class PostsController < ApplicationController\n def index\n end\nend\n",
      "app/views/posts/_card.html.erb" => "<%# locals: (post:, compact: false) %>\n<%= post %>"
    }
    error = assert_raises(Spinrail::CompileError) do
      build(files.merge("app/views/posts/index.html.erb" => %(<%= render "card", compact: true %>)))
    end
    assert_match(/needs local post/, error.message)
    ruby = build(files.merge("app/views/posts/index.html.erb" => %(<%= render "card", post: "x" %>)))
    assert_includes ruby, "def partial_posts_card(post:, compact: false)"
    assert_includes ruby, %(partial_posts_card(post: "x"))
  end

  def test_n_plus_one_warning
    files = {
      "config/routes.rb" => %(Spinrail.routes.draw do\n get "/", to: "posts#index"\nend\n),
      "db/schema.rb" => "Spinrail::Schema.define do\n create_table :posts do |t|\n t.string :title\n end\n create_table :comments do |t|\n t.references :post\n end\nend\n",
      "app/models/post.rb" => "class Post < ApplicationRecord\n has_many :comments\nend\n",
      "app/models/comment.rb" => "class Comment < ApplicationRecord\n belongs_to :post\nend\n",
      "app/controllers/posts_controller.rb" => "class PostsController < ApplicationController\n def index\n @posts = Post.all\n end\nend\n"
    }
    build = Spinrail::Build.new(minimal_app(files.merge("app/views/posts/index.html.erb" => "<% @posts.each do |post| %><%= post.comments.count %><% end %>")))
    build.send(:generate)
    assert_equal 1, build.warnings.size
    assert_match(/post.comments inside a loop/, build.warnings.first)

    build = Spinrail::Build.new(minimal_app(files.merge("app/views/posts/index.html.erb" => "<% @posts.includes(:comments).each do |post| %><%= post.comments.count %><% end %>")))
    build.send(:generate)
    assert_empty build.warnings

    build = Spinrail::Build.new(minimal_app(files.merge("app/views/posts/index.html.erb" => "<% @posts.each do |post| %><% post.comments.create! %><% end %>")))
    build.send(:generate)
    assert_empty build.warnings
  end
end
