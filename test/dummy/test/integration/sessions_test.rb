class SessionsTest < Spinrail::IntegrationTest
  def test_session_and_flash_survive_one_redirect
    post "/session", params: { name: "Ana" }
    assert_redirected_to "/session"
    follow_redirect!
    assert_body_includes "Welcome Ana"
    assert_body_includes "user=Ana visits=1"

    get "/session"
    refute_body_includes "Welcome"
    assert_body_includes "user=Ana"
  end

  def test_session_delete_and_flash_assignment
    post "/session", params: { name: "Ana" }
    post "/session/logout"
    follow_redirect!
    assert_body_includes "<p class=\"alert\">Bye</p>"
    assert_body_includes "user= visits=1"
  end

  def test_flash_now
    get "/session/now"
    assert_body_includes "Only now"
    get "/session"
    refute_body_includes "Only now"
  end
end

class ForgeryProtectionTest < Spinrail::IntegrationTest
  forgery_protection!

  def test_post_without_token_is_rejected
    post "/session", params: { name: "Ana" }
    assert_response 422
  end

  def test_post_with_the_session_token_passes
    get "/session"
    token = response.body[/name="csrf-token" content="([^"]+)"/, 1]
    assert token
    post "/session", params: { name: "Ana", authenticity_token: token }
    assert_redirected_to "/session"
  end

  def test_header_token_passes
    get "/session"
    token = response.body[/name="csrf-token" content="([^"]+)"/, 1]
    post "/session", params: { name: "Ana" }, headers: { "X-CSRF-Token" => token }
    assert_redirected_to "/session"
  end
end
