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
  end
end
