require_relative "helper"

class RoutesTest < CompilerTest
  def routes(body)
    Rieles::Routes.new(File.join(app("config/routes.rb" => "Rieles.routes.draw do\n#{body}\nend\n"), "config/routes.rb"))
  end

  def table(r) = r.routes.map { |x| "#{x.verb.upcase} #{x.path} #{x.controller}##{x.action}" }

  def test_resources_order_new_and_collection_before_member
    r = routes("resources :posts do\n collection do\n get :search\n end\nend")
    paths = table(r)
    assert_operator paths.index("GET /posts/search posts#search"), :<, paths.index("GET /posts/:id posts#show")
    assert_operator paths.index("GET /posts/new posts#new"), :<, paths.index("GET /posts/:id posts#show")
  end

  def test_helpers
    r = routes("resources :posts do\n resources :comments\n member do\n post :publish\n end\nend\nresource :profile\nnamespace :admin do\n resources :users, only: [:index]\nend")
    h = r.helpers
    assert_equal [["post_id", "id"], %("/posts/" + post_id.to_param + "/comments/" + id.to_param)], h["post_comment_path"]
    assert_equal ["id"], h["publish_post_path"][0]
    assert_equal [[], %("/profile")], h["profile_path"]
    assert_equal [[], %("/admin/users")], h["admin_users_path"]
    assert_includes table(r), "GET /admin/users admin/users#index"
  end

  def test_action_class_targets
    r = routes("get \"/stats\", to: Actions::Stats::Show")
    assert_equal [nil, "stats.show"], [r.routes.first.controller, r.routes.first.action]
  end

  def test_bad_target
    assert_raises(Rieles::CompileError) { routes(%(get "/x", to: "nope")) }
  end
end

class RoutesExtrasTest < CompilerTest
  def routes(body)
    Rieles::Routes.new(File.join(app("config/routes.rb" => "Rieles.routes.draw do\n#{body}\nend\n"), "config/routes.rb"))
  end

  def table(r) = r.routes.map { |x| "#{x.verb.upcase} #{x.path} #{x.controller}##{x.action}" }

  def test_shallow
    r = routes("resources :posts do\n resources :comments, shallow: true\nend")
    t = table(r)
    assert_includes t, "GET /posts/:post_id/comments comments#index"
    assert_includes t, "POST /posts/:post_id/comments comments#create"
    assert_includes t, "GET /comments/:id comments#show"
    assert_includes t, "DELETE /comments/:id comments#destroy"
    assert_equal [["id"], %("/comments/" + id.to_param)], r.helpers["comment_path"]
    assert_equal ["post_id"], r.helpers["post_comments_path"][0]
  end

  def test_scope_and_concerns
    r = routes(<<~RUBY)
      concern :commentable do
        resources :comments, only: [:index]
      end
      scope "/v1", module: "api", as: "api" do
        resources :posts, only: [:index], concerns: :commentable
      end
    RUBY
    t = table(r)
    assert_includes t, "GET /v1/posts api/posts#index"
    assert_includes t, "GET /v1/posts/:post_id/comments api/comments#index"
    assert r.helpers.key?("api_posts_path")
    assert r.helpers.key?("api_post_comments_path")
  end
end
