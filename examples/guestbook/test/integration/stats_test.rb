class StatsTest < Rieles::IntegrationTest
  def test_counts_entries
    post "/entries", params: { "entry[name]" => "Ana", "entry[body]" => "one" }
    post "/entries", params: { "entry[name]" => "Bea", "entry[body]" => "two" }

    get "/stats"
    assert_response :success
    assert_body_includes "2 messages"
  end
end
