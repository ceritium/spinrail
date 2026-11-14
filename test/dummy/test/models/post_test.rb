class PostTest < Spinrail::ModelTest
  def setup
    @author = Author.create(name: "Ana", email: "ana@example.com")
  end

  def test_validations
    post = Post.new(author_id: @author.id, title: "x", rating: 9.0)
    assert_not post.valid?
    assert_includes post.errors.full_messages, "Rating must be less than or equal to 5"
  end

  def test_long_text_round_trips
    post = Post.create(author_id: @author.id, title: "Long", body: "x" * 200000, rating: 1.0)
    assert_equal 200000, Post.find(post.id).body.length
  end

  def test_find_raises_for_missing_records
    assert_raises(Spinrail::RecordNotFound) do
      Post.find(12345)
    end
  end

  def test_associations_and_scopes
    post = Post.create(author_id: @author.id, title: "Hello", body: "text", rating: 3.0, published: true)
    post.comments.create(body: "nice")
    assert_equal 1, post.comments.count
    assert_equal ["Hello"], Post.published.pluck(:title)
    assert_nil Post.find_by(title: "Nope")
  end

  def test_no_difference_when_invalid
    assert_no_difference("Post.count") do
      Post.create(author_id: @author.id, title: "", rating: 1.0)
    end
  end

  def test_rows_from_other_tests_are_gone
    assert_equal 0, Post.count
    assert_equal 1, Author.count
  end
end
