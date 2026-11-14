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

  def home
    @posts = Post.order(id: :asc)
    @post = Post.first
  end
end
