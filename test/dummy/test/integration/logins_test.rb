class LoginsTest < Rieles::IntegrationTest
  def test_signup_and_login
    post "/signup", params: { "user[email]" => "ana@example.com", "user[password]" => "pw", "user[password_confirmation]" => "pw" }
    assert_response :success
    refute_body_includes "password_digest"
    post "/login", params: { email: "ana@example.com", password: "pw" }
    assert_equal "welcome ana@example.com", response.body
    post "/login", params: { email: "ana@example.com", password: "nope" }
    assert_response :unauthorized
  end
end
