class RoutesTest < Rieles::IntegrationTest
  def setup
    super
    get "/models/seed"
  end

  def test_nested_resources
    post "/posts/1/comments", params: { body: "nice" }
    assert_equal "http://127.0.0.1:#{port}/posts/1/comments/1", response["Location"]
    get "/posts/1/comments"
    assert_equal "nice /posts/1/comments /posts/1/comments/7", response.body
    get "/posts/1/comments/1"
    assert_equal "comment 1 of 1", response.body
  end

  def test_turbo_stream_response
    post "/posts/1/comments", params: { body: "streamed" }, headers: { "Accept" => "text/vnd.turbo-stream.html, text/html" }
    assert_equal "text/vnd.turbo-stream.html; charset=utf-8", response["Content-Type"]
    assert_equal '<turbo-stream action="append" target="comments"><template><li id="comment_1">streamed</li></template></turbo-stream>' \
                 '<turbo-stream action="update" target="count"><template>1</template></turbo-stream>' \
                 '<turbo-stream action="remove" target="empty"></turbo-stream>', response.body
  end

  def test_nested_form
    get "/posts/1/comments/new"
    assert_select "form[action='/posts/1/comments'] textarea#comment_body"
    assert_select "input[type=submit][value='Create Comment']"
  end

  def test_globs_and_constraints
    get "/files/docs/2026/report.pdf"
    assert_equal "file docs/2026/report.pdf /files/a/b.txt", response.body
    get "/numbers/42"
    assert_equal "number 42", response.body
    get "/numbers/forty"
    assert_equal "word forty", response.body
  end

  def test_collection_comes_before_member
    get "/posts/search"
    assert_equal "search /posts/search /posts/3/publish", response.body
  end

  def test_member_route
    post "/posts/2/publish"
    assert_redirected_to "/posts/2"
    follow_redirect!
    assert_body_includes "published=true"
  end

  def test_namespace
    get "/admin/posts"
    assert_body_includes "admin 3 /admin/posts /admin"
    get "/admin"
    assert_response :success
  end

  def test_singular_resource
    get "/profile"
    assert_equal "profile at /profile", response.body
  end
end
