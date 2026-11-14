require_relative "helper"

class BuildTest < CompilerTest
  def build(files) = Rieles::Build.new(minimal_app(files)).send(:generate)

  def test_template_reading_an_unassigned_ivar
    error = assert_raises(Rieles::CompileError) do
      build(
        "config/routes.rb" => %(Rieles.routes.draw do\n get "/", to: "posts#index"\nend\n),
        "app/controllers/posts_controller.rb" => "class PostsController < ApplicationController\n def index\n end\nend\n",
        "app/views/posts/index.html.erb" => "<%= @posts %>"
      )
    end
    assert_match(/reads @posts, which #index doesn't assign/, error.message)
  end

  def test_before_action_assignments_count
    ruby = build(
      "config/routes.rb" => %(Rieles.routes.draw do\n get "/", to: "posts#index"\nend\n),
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
    error = assert_raises(Rieles::CompileError) do
      build(
        "config/routes.rb" => %(Rieles.routes.draw do\n get "/", to: "posts#helper"\nend\n),
        "app/controllers/posts_controller.rb" => "class PostsController < ApplicationController\n private\n def helper\n end\nend\n"
      )
    end
    assert_match(/PostsController#helper is not defined/, error.message)
  end

  def test_unknown_partial
    assert_raises(Rieles::CompileError) do
      build(
        "config/routes.rb" => %(Rieles.routes.draw do\n get "/", to: "posts#index"\nend\n),
        "app/controllers/posts_controller.rb" => "class PostsController < ApplicationController\n def index\n end\nend\n",
        "app/views/posts/index.html.erb" => %(<%= render "missing" %>)
      )
    end
  end

  def test_strict_locals_are_checked
    files = {
      "config/routes.rb" => %(Rieles.routes.draw do\n get "/", to: "posts#index"\nend\n),
      "app/controllers/posts_controller.rb" => "class PostsController < ApplicationController\n def index\n end\nend\n",
      "app/views/posts/_card.html.erb" => "<%# locals: (post:, compact: false) %>\n<%= post %>"
    }
    error = assert_raises(Rieles::CompileError) do
      build(files.merge("app/views/posts/index.html.erb" => %(<%= render "card", compact: true %>)))
    end
    assert_match(/needs local post/, error.message)
    ruby = build(files.merge("app/views/posts/index.html.erb" => %(<%= render "card", post: "x" %>)))
    assert_includes ruby, "def partial_posts_card(post:, compact: false)"
    assert_includes ruby, %(partial_posts_card(post: "x"))
  end

  def test_n_plus_one_warning
    files = {
      "config/routes.rb" => %(Rieles.routes.draw do\n get "/", to: "posts#index"\nend\n),
      "db/schema.rb" => "Rieles::Schema.define do\n create_table :posts do |t|\n t.string :title\n end\n create_table :comments do |t|\n t.references :post\n end\nend\n",
      "app/models/post.rb" => "class Post < ApplicationRecord\n has_many :comments\nend\n",
      "app/models/comment.rb" => "class Comment < ApplicationRecord\n belongs_to :post\nend\n",
      "app/controllers/posts_controller.rb" => "class PostsController < ApplicationController\n def index\n @posts = Post.all\n end\nend\n"
    }
    build = Rieles::Build.new(minimal_app(files.merge("app/views/posts/index.html.erb" => "<% @posts.each do |post| %><%= post.comments.count %><% end %>")))
    build.send(:generate)
    assert_equal 1, build.warnings.size
    assert_match(/post.comments inside a loop/, build.warnings.first)

    build = Rieles::Build.new(minimal_app(files.merge("app/views/posts/index.html.erb" => "<% @posts.includes(:comments).each do |post| %><%= post.comments.count %><% end %>")))
    build.send(:generate)
    assert_empty build.warnings
  end
end
