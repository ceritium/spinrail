require "json"

class FeaturesTest < Spinrail::IntegrationTest
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

  def test_throw_abort_cancels_destroy
    get "/models/abort"
    assert_equal "destroyed=false still=1", response.body
  end

  def test_signed_and_permanent_cookies
    get "/models/signed?uid=42"
    assert_match(/\A42--\h{64}\z/, cookies["uid"])
    assert_match(/Max-Age=630720000/, response.get_fields("set-cookie").join)
    get "/models/signed"
    assert_equal "uid=42", response.body
    cookies["uid"] = "43--" + cookies["uid"].split("--").last
    get "/models/signed"
    assert_equal "uid=", response.body
  end

  def test_json_suffix
    get "/models/formats.json"
    assert_equal "First", JSON.parse(response.body)["title"]
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
    assert_includes body, '<span class="badge">&lt;new&gt;</span>'
    assert_includes body, "<p>$1,234.50 -€5</p>"
    assert_includes body, "<p>less than a minute</p>"
    assert_includes body, '<a href="/posts/1" class="card"><strong>First</strong></a>'
    href = body[%r{<link rel="stylesheet" href="(/style-\h{12}\.css)" media="all">}, 1]
    assert href, body
    get href
    assert_equal "body { color: #333; }\n", response.body
    assert_equal "public, max-age=31536000, immutable", response["Cache-Control"]
    get "/style.css"
    assert_response :success
    assert_includes body, '<script src="https://cdn.example.com/x.js" defer></script>'
    assert_includes body, '<img src="/logo.png" alt="Logo">'
  end
end
