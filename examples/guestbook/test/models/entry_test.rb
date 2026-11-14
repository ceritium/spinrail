class EntryTest < ActiveSupport::TestCase
  fixtures :entries

  def test_fixtures_are_loaded
    assert_equal "Ana", entries(:hello).name
    assert_equal 2, Entry.count
  end

  def test_requires_name_and_body
    entry = Entry.new(name: "", body: "")
    assert_not entry.valid?
    assert_includes entry.errors.full_messages, "Name can't be blank"
  end

  def test_excerpt_cuts_long_bodies
    entry = Entry.new(name: "Ana", body: "x" * 200)
    assert_equal 121, entry.excerpt.length
  end

  def test_create_adds_a_row
    assert_difference("Entry.count", 1) do
      Entry.create(name: "Bea", body: "hi")
    end
  end

  def test_each_test_starts_from_the_fixtures
    assert_equal 2, Entry.count
  end
end
