class Views::Reports::Show < Spinrail::View
  expose :posts, :title
  expose :heading do |title, posts|
    title + " (" + posts.count.to_s + ")"
  end

  def stars(rating)
    "*" * rating.to_i
  end
end
