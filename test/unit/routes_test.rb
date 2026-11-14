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
