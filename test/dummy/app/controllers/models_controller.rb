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
    lines << "in=" + Post.where(title: ["First", "Third", "Nope"]).order(id: :asc).pluck(:title).join(",") + ";" + Post.where(title: []).count.to_s
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

  def scoped
    post = Post.find_by(title: "First")
    built = post.comments.create(body: "a very long comment")
    unsaved = post.comments.new(body: "draft")
    lines = []
    lines << "built=" + built.post_id.to_s + " " + built.persisted?.to_s + " " + built.body
    lines << "unsaved=" + unsaved.post_id.to_s + " " + unsaved.persisted?.to_s
    lines << "count=" + post.comments.count.to_s + " includes=" + Post.includes(:comments).count.to_s
    blank = Post.new(author_id: post.author_id, title: "Blank", body: "", rating: 1.0, published: true)
    hidden = Post.new(author_id: post.author_id, title: "Blank", body: "", rating: 1.0, published: false)
    lines << "guard=" + blank.valid?.to_s + "," + hidden.valid?.to_s
    render plain: lines.join("\n")
  end

  def scopes
    Post.where(title: "Second").update_all(views: 7, published: true)
    lines = []
    lines << "published=" + Post.published.count.to_s
    lines << "chained=" + Post.published.order(id: :desc).pluck(:title).join(",")
    lines << "arg=" + Post.rated_above(2).pluck(:title).join(",")
    lines << "views=" + Post.find_by(title: "Second").views.to_s
    render plain: lines.join("\n")
  end

  def formats
    @post = Post.first
    respond_to do |format|
      format.html { render plain: "html " + @post.title }
      format.json { render json: @post }
    end
  end

  def cookie
    cookies[:theme] = params[:theme] unless params[:theme].empty?
    cookies.delete(:old) if params[:clear] == "1"
    render plain: "theme=" + cookies[:theme].to_s
  end

  def helpers
    @post = Post.first
    render :helpers, layout: "bare"
  end

  def eager
    first = Post.find_by(title: "First")
    Comment.create(post_id: first.id, body: "c1")
    Comment.create(post_id: first.id, body: "c2")
    lines = Post.order(id: :asc).includes(:comments, :author).to_a.map do |post|
      post.title + ":" + post.author.name + ":" + post.comments.count.to_s + ":" + post.comments.pluck(:body).join("|")
    end
    render plain: lines.join("\n")
  end

  def abort
    post = Post.find_by(title: "First")
    post.title = "Locked"
    post.save
    destroyed = post.destroy
    render plain: "destroyed=" + destroyed.to_s + " still=" + Post.where(title: "Locked").count.to_s
  end

  def signed
    cookies.signed[:uid] = params[:uid] unless params[:uid].empty?
    cookies.permanent[:seen] = "yes"
    render plain: "uid=" + cookies.signed[:uid].to_s
  end

  def nulls
    post = Post.find_by(title: "First")
    lines = []
    lines << "initial=" + post.subtitle.inspect + "," + post.priority.inspect
    lines << "null_count=" + Post.where(subtitle: nil).count.to_s + " not_null=" + Post.where.not(subtitle: nil).count.to_s
    post.update(subtitle: "Sub", priority: 3)
    fresh = Post.find(post.id)
    lines << "set=" + fresh.subtitle.to_s + "," + fresh.priority.to_s + " not_null=" + Post.where.not(subtitle: nil).count.to_s
    fresh.update(subtitle: nil, priority: nil)
    again = Post.find(post.id)
    lines << "cleared=" + again.subtitle.inspect + "," + again.priority.inspect
    lines << "pluck=" + Post.order(id: :asc).pluck(:priority).inspect
    lines << "json=" + again.to_json.include?("\"subtitle\":null").to_s
    render plain: lines.join("\n")
  end

  def big
    post = Post.find_by(title: "First")
    post.update(body: "x" * 70000)
    render plain: Post.find(post.id).body.length.to_s
  end

  def joins
    first = Post.find_by(title: "First")
    Comment.create(post_id: first.id, body: "c1")
    Comment.create(post_id: first.id, body: "c2")
    lines = []
    lines << "by_author=" + Post.joins(:author).where(authors: { name: "Ana" }).order(id: :asc).pluck(:title).join(",")
    lines << "mixed=" + Post.joins(:author).where(published: true, authors: { name: "Ana" }).count.to_s
    lines << "with_comments=" + Post.joins(:comments).count.to_s
    lines << "left=" + Post.left_joins(:comments).distinct.count.to_s + " distinct=" + Post.joins(:comments).distinct.count.to_s
    counts = Post.group(:status).count
    lines << "groups=" + counts.keys.sort.map { |k| k + ":" + counts[k].to_s }.join(",")
    render plain: lines.join("\n")
  end

  def shout
    ShoutJob.perform_later(Author.find_by(name: "Ana").id)
    BrokenJob.perform_later("x") if params[:broken] == "1"
    if params[:flaky] == "1"
      FlakyJob.perform_later("flaky")
      FlakyJob.perform_later("unwanted")
    end
    seconds = params[:seconds].to_s.empty? ? "0.5" : params[:seconds].to_s
    params[:slow].to_i.times { SlowJob.perform_later(seconds) }
    render plain: "queued"
  end

  def serial
    groups = params[:groups].to_s
    if groups.empty?
      %w[a a a b].each { |group| SerialJob.perform_later(group) }
      2.times { OnceJob.perform_later("x") }
    else
      groups.split(",").each { |group| SerialJob.perform_later(group) }
    end
    render plain: "queued"
  end

  def enqueue
    NoteJob.set(wait: 2.seconds).perform_later("later")
    NoteJob.perform_later("low")
    NoteJob.set(queue: :default, priority: 5).perform_later("d", "5")
    NoteJob.set(queue: :default, priority: 0).perform_later("d", "0")
    render plain: "queued"
  end

  def cached
    Rails.cache.delete("count") if params[:reset] == "1"
    count = Rails.cache.fetch("count", expires_in: 5.minutes) { Post.count.to_s }
    @post = Post.find_by(title: "First")
    @count = count
    @live = Post.count.to_s
    @post.update(body: "touched " + params[:touch]) unless params[:touch].empty?
  end

  def authors
    render plain: Author.order(id: :asc).pluck(:name).join(",")
  end

  def bang
    Author.create!(name: "", email: "x")
    render plain: "unreachable"
  end
end
