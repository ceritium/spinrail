class PostsTest < Spinrail::IntegrationTest
  def setup
    super
    get "/models/seed"
  end

  def test_new_form_is_scoped_to_the_model
    get "/posts/new"
    assert_response :success
    assert_body_includes 'name="post[title]" id="post_title"'
    assert_body_includes '<label for="post_body">Text</label>'
    assert_body_includes 'value="Create Post"'
    assert_body_includes '<option value="draft" selected>'
    assert_select "select#post_author_id option[value='1'][selected]", "Ana"
  end

  def test_create_with_strong_params
    post "/posts", params: { "post[title]" => "Fourth", "post[body]" => "text", "post[rating]" => "1.5",
                             "post[published]" => "1", "post[author_id]" => "1", "post[views]" => "99" }
    assert_redirected_to "/posts/4"
    follow_redirect!
    assert_body_includes "Post created"
    assert_body_includes "published=true rating=1.5 status=draft"
  end

  def test_create_from_a_json_body
    post "/posts", json: { post: { title: "From JSON", body: "line \"one\"\nline two", rating: 2.5, published: true, author_id: 2 } }
    assert_redirected_to "/posts/4"
    follow_redirect!
    assert_body_includes "<h1>From JSON</h1>"
    assert_body_includes "published=true rating=2.5"
  end

  def test_invalid_create_rerenders_the_form
    post "/posts", params: { "post[title]" => "x", "post[author_id]" => "1" }
    assert_response :unprocessable_entity
    assert_body_includes "Title is too short"
    assert_select "div.field_with_errors input#post_title"
    assert_body_includes 'value="x"'
  end

  def test_missing_scope_is_bad_request
    post "/posts", params: { title: "Flat" }
    assert_response :bad_request
  end

  def test_edit_and_update_through_method_override
    get "/posts/1/edit"
    assert_body_includes '<input type="hidden" name="_method" value="patch">'
    assert_body_includes 'value="Update Post"'
    assert_body_includes 'checked'

    post "/posts/1", params: { "_method" => "patch", "post[title]" => "Renamed", "post[published]" => "0" }
    assert_redirected_to "/posts/1"
    follow_redirect!
    assert_body_includes "<h1>Renamed</h1>"
    assert_body_includes "published=false"
  end

  def test_pagination
    get "/posts"
    assert_select "ul a.post", count: 2
    assert_select "nav.pagination span.current", "1"
    assert_select "nav.pagination a[rel=next][href='?page=2']"
    get "/posts?page=2"
    assert_select "ul a.post", "Third"
    assert_select "nav.pagination a[rel=prev][href='?page=1']"
  end

  def test_destroy_from_button_to
    get "/posts"
    assert_body_includes '<a href="/posts/1" class="post" data-id="1">First</a>'
    assert_body_includes '<input type="hidden" name="_method" value="delete">'
    delete "/posts/1"
    assert_redirected_to "/posts"
    follow_redirect!
    assert_body_includes "Post deleted"
    refute_body_includes ">First<"
    assert_select "ul a.post", count: 2
  end
end
