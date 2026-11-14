class CommentsController < ApplicationController
  before_action :set_post

  def index
    render plain: @post.comments.pluck(:body).join(",") + " " + post_comments_path(@post) + " " + post_comment_path(@post, 7)
  end

  def new
    @comment = @post.comments.new
  end

  def show
    render plain: "comment " + params[:id] + " of " + params[:post_id]
  end

  def create
    comment = Comment.create(post_id: @post.id, body: params[:body])
    respond_to do |format|
      format.html { redirect_to post_comment_url(@post, comment) }
      format.turbo_stream do
        render turbo_stream: [
          turbo_stream.append("comments", partial: "comments/comment", locals: { comment: comment }),
          turbo_stream.update("count", @post.comments.count.to_s),
          turbo_stream.remove("empty")
        ]
      end
    end
  end

  private

  def set_post
    @post = Post.find(params[:post_id])
  end
end
