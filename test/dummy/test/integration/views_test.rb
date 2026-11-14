class ViewsTest < Rieles::IntegrationTest
  def setup
    super
    get "/models/seed"
  end

  def test_content_for_and_yield
    get "/home"
    assert_response :success
    assert_body_includes "<title>Home</title>"
    assert_match %r{<footer>\s*<a href="/about">About US!</a>\s*</footer>}, response.body
  end

  def test_collection_partials
    get "/home"
    assert_match %r{<ul>\n<li class="item">First</li><li class="item">Second</li><li class="item">Third</li>\n</ul>}, response.body
    assert_body_includes '<ol><li class="item">First</li><li class="item">Second</li><li class="item">Third</li></ol>'
  end

  def test_default_title
    get "/posts"
    assert_body_includes "<title>test</title>"
  end

  def test_controller_layout
    get "/bare"
    assert_equal %(<main class="bare"><p>no chrome</p>\n</main>\n), response.body
  end

  def test_layout_false
    get "/plain"
    assert_equal "<p>plain</p>\n", response.body
  end
end
