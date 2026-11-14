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

  def test_welcome_mail
    post "/signup", params: { "user[email]" => "bea@example.com", "user[password]" => "pw" }
    assert_equal 1, deliveries.size
    mail = deliveries.first
    assert_equal "bea@example.com", mail.to
    assert_equal "hello@example.com", mail.from
    assert_equal "Welcome, bea@example.com", mail.subject
    assert_equal "Hi bea@example.com & friends,\nLog in at http://example.com/login.\n", mail.body
    assert_equal "<p>Hi bea@example.com &amp; friends</p>\n", mail.html
  end

  def test_deliver_later_goes_through_jobs
    post "/signup", params: { "user[email]" => "cid@example.com", "user[password]" => "pw", later: "1" }
    assert_equal ["cid@example.com"], deliveries.map(&:to)
  end
end
