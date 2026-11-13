class StatsTest < Rieles::IntegrationTest
  def test_counts_entries
    post "/entries", params: { name: "Ana", body: "one" }
    post "/entries", params: { name: "Bea", body: "two" }

    get "/stats"
    assert_response :success
    assert_body_includes "2 messages"
  end
end
