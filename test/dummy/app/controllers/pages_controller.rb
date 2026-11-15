class PagesController < ApplicationController
  def file
    render plain: "file " + params[:path] + " " + files_path("a/b.txt")
  end

  def number
    render plain: "number " + params[:n]
  end

  def word
    render plain: "word " + params[:word]
  end

  def badge
    @label = params[:label]
    expires_in 30.minutes, public: true
    render formats: :svg
  end

  def mark
    send_file Rails.root.join("app/views/pages/mark.svg"), content_type: "image/svg+xml", disposition: :inline
  end

  def home
    @posts = Post.order(id: :asc)
    @post = Post.first
  end
end
