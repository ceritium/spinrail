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
end
