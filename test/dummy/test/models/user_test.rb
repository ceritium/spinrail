class UserTest < Spinrail::ModelTest
  def test_hashes_and_authenticates
    user = User.create(email: "ana@example.com", password: "secret123")
    assert user.persisted?
    assert user.password_digest.start_with?("pbkdf2-sha256$")
    fresh = User.find(user.id)
    assert fresh.authenticate("secret123")
    assert_not fresh.authenticate("wrong")
  end

  def test_requires_a_password_and_matching_confirmation
    user = User.new(email: "bea@example.com")
    assert_not user.valid?
    assert_includes user.errors.full_messages, "Password can't be blank"
    user = User.new(email: "bea@example.com", password: "a", password_confirmation: "b")
    assert_not user.valid?
    assert_includes user.errors.full_messages, "Password confirmation doesn't match Password"
  end

  def test_update_keeps_the_digest_without_a_new_password
    user = User.create(email: "cid@example.com", password: "one")
    digest = user.password_digest
    user.update(email: "cid2@example.com")
    assert_equal digest, User.find(user.id).password_digest
    user.update(password: "two")
    assert User.find(user.id).authenticate("two")
  end
end
