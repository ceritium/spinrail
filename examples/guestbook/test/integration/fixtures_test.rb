class FixturesTest < Spinrail::IntegrationTest
  fixtures :entries

  def test_index_lists_the_fixtures
    get "/"
    assert_select "h2", "2 messages"
    assert_select "ul.entries li", count: 2
    assert_select "ul.entries li", /Hello from a fixture/
  end

  def test_fixture_ids_are_stable
    get "/entries/#{entries(:hello).id}"
    assert_response :success
    assert_select "article p", entries(:hello).body
  end
end
