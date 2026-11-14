class ModelsTest < Rieles::IntegrationTest
  def setup
    super
    get "/models/seed"
    assert_response :success
  end

  def test_seed_runs_callbacks
    assert_equal "authors=2 posts=3 email=ana@example.com", response.body
  end

  def test_query_api
    get "/models/query"
    assert_response :success
    expected = <<~TEXT.chomp
      visible=First,Third
      not_published=Second
      first=First last=Third
      by_rating=Second,Third,First
      offset=Second
      count=2
      exists=true,false
      find_by=Second,nil
      ratings=4.5,2.0,3.25
      published?=true
      immutable=Third,2
    TEXT
    assert_equal expected, response.body
  end

  def test_validations
    get "/models/validations"
    assert_response :success
    expected = <<~TEXT.chomp
      valid=false
      Title is too short (minimum is 3 characters)
      Rating must be less than or equal to 5
      Status is not included in the list
      Author must exist
      Body is shouting
      dup=false Email has already been taken
      bad=Name can't be blank,Email is invalid
      orphan=0
      orphan_errors=Post must exist
    TEXT
    assert_equal expected, response.body
  end

  def test_associations
    get "/models/associations"
    assert_response :success
    expected = <<~TEXT.chomp
      author=Ana
      comments=one,two
      ana_posts=2
      updated=First!
      after_destroy posts=1 comments=0 authors=1
    TEXT
    assert_equal expected, response.body
  end

  def test_transaction_rolls_back
    get "/models/transaction"
    assert_equal "cid=0", response.body
  end

  def test_bang_methods_raise_unprocessable
    get "/models/bang"
    assert_response 422
    assert_body_includes "Validation failed: Name can&#39;t be blank, Email is invalid"
  end
end

class ModelsScopedTest < Rieles::IntegrationTest
  def setup
    super
    get "/models/seed"
  end

  def test_building_through_associations_and_guards
    get "/models/scoped"
    expected = <<~TEXT.chomp
      built=1 true a very lon
      unsaved=1 false
      count=1 includes=3
      guard=false,true
    TEXT
    assert_equal expected, response.body
  end
end

class SeedsTest < Rieles::IntegrationTest
  def test_seeds_run_against_the_database
    assert system({ "RIELES_SEED" => "1", "DATABASE_PATH" => database_path, "DATABASE_URL" => database_path,
                    "RIELES_LOG_LEVEL" => "error" },
                  ENV.fetch("RIELES_BINARY"), out: File::NULL)
    get "/models/authors"
    assert_equal "Seeded", response.body
  end
end

class BigTextTest < Rieles::IntegrationTest
  def test_text_over_64_kb_comes_back_whole
    get "/models/seed"
    get "/models/big"
    assert_response 200
    assert_equal "70000", response.body
  end
end

class NullableTest < Rieles::IntegrationTest
  def test_nullable_columns
    get "/models/seed"
    get "/models/nulls"
    expected = <<~TEXT.chomp
      initial=nil,nil
      null_count=3 not_null=0
      set=Sub,3 not_null=1
      cleared=nil,nil
      pluck=[nil, nil, nil]
      json=true
    TEXT
    assert_equal expected, response.body
  end
end

class JoinsTest < Rieles::IntegrationTest
  def test_joins_and_group
    get "/models/seed"
    get "/models/joins"
    expected = <<~TEXT.chomp
      by_author=First,Second
      mixed=1
      with_comments=2
      left=3 distinct=1
      groups=draft:3
    TEXT
    assert_equal expected, response.body
  end
end
