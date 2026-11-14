class CacheTest < Rieles::IntegrationTest
  def test_fetch_and_fragments
    get "/models/seed"
    get "/models/cached"
    assert_select "p.count", "3 3"
    assert_select "p.frag", "First 3"

    post "/posts", params: { "post[title]" => "Fourth", "post[author_id]" => "1", "post[rating]" => "1" }
    get "/models/cached"
    assert_select "p.count", "3 4"
    assert_select "p.frag", "First 3"

    get "/models/cached?reset=1&touch=1"
    assert_select "p.count", "4 4"
    assert_select "p.frag", "First 4"
  end
end

class SharedCacheTest < CacheTest
  server_env "RIELES_CACHE_STORE" => "sqlite"
end
