class PostsController < ApplicationController
  before_action :set_post, only: [:show, :edit, :update, :destroy, :publish]

  def index
    @posts = Post.order(id: :asc).page(params[:page]).per(2)
  end

  def show
  end

  def new
    @post = Post.new(author_id: Author.first.id)
  end

  def edit
  end

  def create
    @post = Post.new(post_params)
    if @post.save
      redirect_to post_path(@post), notice: "Post created"
    else
      render :new, status: :unprocessable_entity
    end
  end

  def update
    if @post.update(post_params)
      redirect_to post_path(@post), notice: "Post updated", status: :see_other
    else
      render :edit, status: :unprocessable_entity
    end
  end

  def search
    render plain: "search " + search_posts_path + " " + publish_post_path(3)
  end

  def publish
    @post.update(published: true)
    redirect_to post_path(@post.id)
  end

  def destroy
    @post.destroy
    redirect_to posts_path, notice: "Post deleted", status: :see_other
  end

  private

  def set_post
    @post = Post.find(params[:id])
  end

  def post_params
    params.require(:post).permit(:title, :body, :published, :rating, :status, :author_id)
  end
end
