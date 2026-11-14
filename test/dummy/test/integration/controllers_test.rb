require "json"

class ControllersTest < Spinrail::IntegrationTest
  def setup
    super
    get "/models/seed"
  end

  def test_before_action_assigns_for_the_action
    get "/widgets/1"
    assert_equal "First en", response.body
    assert_equal "yes", response["X-After"]
  end

  def test_render_json
    get "/widgets"
    assert_equal "application/json", response["Content-Type"]
    json = JSON.parse(response.body)
    assert_equal "en", json["locale"]
    assert_equal 3, json["count"]
    assert_equal "First", json["posts"][0]["title"]
    assert_equal true, json["posts"][0]["published"]
    assert_equal 4.5, json["posts"][0]["rating"]
    assert_equal ["a", "b"], json["tags"]
  end

  def test_before_action_halts
    patch "/widgets/1", params: { title: "Nope" }
    assert_response :unauthorized
    assert_equal "denied", response.body
    refute response["X-After"]
  end

  def test_method_override_and_update
    post "/widgets/1", params: { _method: "patch", title: "Renamed", token: "secret" }
    assert_response :success
    assert_equal "updated Renamed", response.body
  end

  def test_head
    delete "/widgets/2?token=secret"
    assert_response :no_content
    get "/widgets/2"
    assert_response :not_found
    assert_equal "no widget", response.body
  end

  def test_skip_before_action
    get "/open"
    assert_equal "open []", response.body
  end

  def test_rescue_from_in_application_controller
    get "/boom"
    assert_response :bad_request
    assert_equal "bad: nope", response.body
  end

  def test_http_basic_auth
    get "/admin/secret"
    assert_response :unauthorized
    assert_equal 'Basic realm="Application"', response["WWW-Authenticate"]
    get "/admin/secret", headers: { "Authorization" => "Basic " + ["admin:wrong"].pack("m0") }
    assert_response :unauthorized
    get "/admin/secret", headers: { "Authorization" => "Basic " + ["admin:s3cret"].pack("m0") }
    assert_equal "the secret", response.body
    get "/admin/open"
    assert_equal "open", response.body
  end
end
