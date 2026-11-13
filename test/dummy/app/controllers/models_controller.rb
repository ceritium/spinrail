class ModelsController < ApplicationController
  def seed
    ana = Author.create(name: "Ana", email: " ANA@example.com ")
    bea = Author.create(name: "Bea", email: "bea@example.com")
    Post.create(author_id: ana.id, title: "First", body: "hello", published: true, rating: 4.5)
    Post.create(author_id: ana.id, title: "Second", body: "draft text", rating: 2.0)
    Post.create(author_id: bea.id, title: "Third", body: "more", published: true, rating: 3.25)
    render plain: "authors=#{Author.count} posts=#{Post.count} email=#{ana.email}"
  end

  def query
    lines = []
    lines << "visible=" + Post.visible.pluck(:title).join(",")
    lines << "not_published=" + Post.where.not(published: true).pluck(:title).join(",")
    lines << "first=" + Post.first.title + " last=" + Post.last.title
    lines << "by_rating=" + Post.order("rating ASC").pluck(:title).join(",")
    lines << "offset=" + Post.order(id: :asc).limit(1).offset(1).pluck(:title).join(",")
    lines << "count=" + Post.where(published: true).count.to_s
    lines << "exists=" + Post.exists?(title: "Third").to_s + "," + Post.exists?(title: "Nope").to_s
    found = Post.find_by(title: "Second")
    missing = Post.find_by(title: "Nope")
    lines << "find_by=" + (found ? found.title : "nil") + "," + (missing ? missing.title : "nil")
    lines << "ratings=" + Post.order(id: :asc).pluck(:rating).map { |r| r.to_s }.join(",")
    lines << "published?=" + Post.first.published?.to_s
    scope = Post.where(published: true)
    lines << "immutable=" + scope.order(rating: :asc).first.title + "," + scope.count.to_s
    render plain: lines.join("\n")
  end

  def validations
    lines = []
    post = Post.new(title: "x", rating: 9.0, status: "gone", body: "LOUD NOISES")
    lines << "valid=" + post.valid?.to_s
    post.errors.full_messages.each { |m| lines << m }
    author = Author.new(name: "Ana", email: "ana@example.com")
    lines << "dup=" + author.valid?.to_s + " " + author.errors.full_messages.join(",")
    bad = Author.new(name: "", email: "nope")
    bad.valid?
    lines << "bad=" + bad.errors.full_messages.join(",")
    lines << "orphan=" + Comment.new(post_id: 999, body: "hi").errors.count.to_s
    orphan = Comment.new(post_id: 999, body: "hi")
    orphan.valid?
    lines << "orphan_errors=" + orphan.errors.full_messages.join(",")
    render plain: lines.join("\n")
  end

  def associations
    lines = []
    post = Post.find_by(title: "First")
    Comment.create(post_id: post.id, body: "one")
    Comment.create(post_id: post.id, body: "two")
    lines << "author=" + post.author.name
    lines << "comments=" + post.comments.pluck(:body).join(",")
    ana = Author.find_by(name: "Ana")
    lines << "ana_posts=" + ana.posts.count.to_s
    post.update(title: "First!")
    lines << "updated=" + Post.find(post.id).title
    ana.destroy
    lines << "after_destroy posts=" + Post.count.to_s + " comments=" + Comment.count.to_s + " authors=" + Author.count.to_s
    render plain: lines.join("\n")
  end

  def transaction
    begin
      Post.transaction do
        Author.create(name: "Cid", email: "cid@example.com")
        raise ArgumentError, "rollback"
      end
    rescue ArgumentError
      nil
    end
    render plain: "cid=" + Author.where(name: "Cid").count.to_s
  end

  def bang
    Author.create!(name: "", email: "x")
    render plain: "unreachable"
  end
end
