class FeaturesTest < Rieles::ModelTest
  def setup
    @author = Author.create(name: "Ana", email: "ana@example.com")
  end

  def test_enum
    post = Post.create(author_id: @author.id, title: "Hello", rating: 1.0)
    assert_equal "article", post.kind
    assert post.article?
    post.note!
    fresh = Post.find(post.id)
    assert_equal "note", fresh.kind
    assert fresh.note?
    assert_equal 1, Post.note.count
    assert_equal 0, Post.article.count
    assert_equal 1, Post.where(kind: "note").count
    assert_equal 1, Post.kinds["note"]
    post.kind = "bogus"
    assert_not post.valid?
    assert_includes post.errors.full_messages, "Kind is not included in the list"
  end

  def test_confirmation_and_acceptance
    signup = Newsletter.new(email: "a@b.c", email_confirmation: "x@b.c", terms_of_service: "1")
    assert_not signup.valid?
    assert_includes signup.errors.full_messages, "Email confirmation doesn't match Email"
    signup = Newsletter.new(email: "a@b.c", email_confirmation: "a@b.c")
    assert_not signup.valid?
    assert_includes signup.errors.full_messages, "Terms of service must be accepted"
    assert Newsletter.new(email: "a@b.c", terms_of_service: "1").valid?
  end
end
