class Admin::PostsController < ApplicationController
  def index
    @posts = Post.order(id: :asc)
  end
end
