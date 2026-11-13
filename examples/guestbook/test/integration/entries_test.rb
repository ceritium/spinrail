class EntriesTest < Rieles::IntegrationTest
  def test_index_starts_empty
    get "/"
    assert_response :success
    assert_body_includes "0 messages"
  end

  def test_create_redirects_to_the_entry
    post "/entries", params: { name: "José", body: "¡Hola!" }
    assert_response :see_other
    assert_redirected_to "/entries/1"

    follow_redirect!
    assert_response :success
    assert_body_includes "José"
    assert_body_includes "¡Hola!"
  end

  def test_invalid_entry_renders_errors
    post "/entries", params: { name: "", body: "" }
    assert_response :unprocessable_entity
    assert_equal "Unprocessable Content", response.message
    assert_body_includes "Name can&#39;t be blank"
  end

  def test_output_is_escaped
    post "/entries", params: { name: "<b>x</b>", body: "hi" }
    follow_redirect!
    assert_body_includes "&lt;b&gt;x&lt;/b&gt;"
    refute_body_includes "<b>x</b>"
  end

  def test_missing_entry_is_not_found
    get "/entries/99"
    assert_response :not_found
  end
end
