class PagesController < ApplicationController
  def home
    @posts = Post.order(id: :asc)
    @post = Post.first
  end
end
