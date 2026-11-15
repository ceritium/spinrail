# Leaves an author behind, so the order jobs ran in shows in /models/authors.
class NoteJob < ApplicationJob
  queue_as :low
  queue_with_priority 3

  def perform(name, suffix = "")
    Author.create!(name: name + suffix, email: name + suffix + Author.count.to_s + "@example.com")
  end
end
