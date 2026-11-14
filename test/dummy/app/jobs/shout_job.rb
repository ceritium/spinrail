class ShoutJob < ApplicationJob
  queue_as :default

  def perform(author_id)
    author = Author.find(author_id)
    author.update(name: author.name + "!")
  end
end
