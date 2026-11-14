require "json"

class FeaturesTest < Rieles::IntegrationTest
  def setup
    super
    get "/models/seed"
  end

  def test_scopes_and_update_all
    get "/models/scopes"
    expected = <<~TEXT.chomp
      published=3
      chained=Third,Second,First
      arg=First,Third
      views=7
    TEXT
    assert_equal expected, response.body
  end

  def test_respond_to
    get "/models/formats"
    assert_equal "html First", response.body
    get "/models/formats", headers: { "Accept" => "application/json" }
    assert_equal "First", JSON.parse(response.body)["title"]
    get "/models/formats?format=json"
    assert_equal "application/json", response["Content-Type"]
  end

  def test_cookies
    get "/models/cookie?theme=dark"
    assert_equal "theme=", response.body
    get "/models/cookie"
    assert_equal "theme=dark", response.body
  end

  def test_view_helpers_and_render_layout
    get "/models/helpers"
    body = response.body
    assert body.start_with?('<main class="bare">'), body
    assert_includes body, "<p>Hello w...</p>"
    assert_includes body, "<p>one<br>two</p>\n<p>&lt;b&gt;three&lt;/b&gt;</p>"
    assert_includes body, "1,234,567 -1,234.5"
    assert_includes body, 'id="post_1"'
  end
end
