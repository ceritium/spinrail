class WidgetsController < ApplicationController
  before_action :load_widget, only: [:show, :update, :destroy]
  before_action :require_token, except: [:index, :show, :open, :boom]
  skip_before_action :set_locale, only: [:open]
  after_action :tag
  rescue_from Spinrail::RecordNotFound, with: :missing

  def index
    render json: { locale: @locale, count: Post.count, posts: Post.order(id: :asc).limit(1), tags: ["a", "b"], ok: true }
  end

  def show
    render plain: @widget.title + " " + @locale
  end

  def update
    return render(plain: "taken", status: :conflict) if params[:title] == "taken"
    @widget.update(title: params[:title])
    render plain: "updated " + @widget.title
  end

  def destroy
    @widget.destroy
    head :no_content
  end

  def open
    render plain: "open [" + @locale.to_s + "]"
  end

  def boom
    raise ArgumentError, "nope"
  end

  private

  def load_widget
    @widget = Post.find(params[:id])
  end

  def require_token
    render plain: "denied", status: :unauthorized unless params[:token] == "secret"
  end

  def tag
    response.headers["X-After"] = "yes"
  end

  def missing
    render plain: "no widget", status: :not_found
  end
end
