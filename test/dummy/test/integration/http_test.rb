class HttpTest < Spinrail::IntegrationTest
  def test_probe_fetches_its_own_server
    get "/http/probe"
    assert_response :success
    assert_body_includes "status=200"
    assert_body_includes "<p>plain</p>"
  end

  def test_probe_json_parses_the_response
    get "/http/probe_json"
    assert_response :success
    assert_body_includes "ok=true"
    assert_body_includes "tags=2"
  end

  def test_probe_follows_relative_redirects
    get "/http/probe_redirect"
    assert_response :success
    assert_body_includes "status=200"
    assert_body_includes "<p>plain</p>"
  end
end
