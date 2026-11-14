class ActionsTest < Rieles::IntegrationTest
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
end
