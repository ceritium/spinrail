class CommentsController < ApplicationController
  before_action :set_post

  def index
    render plain: @post.comments.pluck(:body).join(",") + " " + post_comments_path(@post) + " " + post_comment_path(@post, 7)
  end

  def show
    render plain: "comment " + params[:id] + " of " + params[:post_id]
  end

  def create
    comment = Comment.create(post_id: @post.id, body: params[:body])
    redirect_to post_comment_url(@post, comment)
  end

  private

  def set_post
    @post = Post.find(params[:post_id])
  end
end
