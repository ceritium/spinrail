class ActionsTest < Spinrail::IntegrationTest
  def setup
    super
    get "/models/seed"
  end

  def test_computed_exposures_and_view_methods
    get "/report"
    assert_response :success
    assert_body_includes "<h1>Report (3)</h1>"
    assert_body_includes "<p>First ****</p><p>Second **</p><p>Third ***</p>"
  end

  def test_halt
    get "/report?key=bad"
    assert_response :forbidden
    assert_equal "no access", response.body
    get "/report?key=gone"
    assert_response :not_found
    assert_equal "Not Found", response.body
  end

  def test_status
    get "/report?key=later"
    assert_response 202
  end

  def test_params_validation
    post "/signups", params: { "user[name]" => "Ana", "user[age]" => "30", "newsletter" => "true" }
    assert_response 201
    post "/signups", params: { "user[name]" => "", "user[age]" => "x", "newsletter" => "maybe" }
    assert_response 422
    assert_equal "Name must be filled, Age must be an integer, Newsletter must be boolean", response.body
    post "/signups", params: {}
    assert_equal "User is missing", response.body
  end
end
