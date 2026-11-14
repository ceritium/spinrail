require_relative "helper"

class LoweringTest < CompilerTest
  def test_params
    assert_equal %(param("id")), lower("params[:id]")
    assert_equal %(param("post[author][name]")), lower("params[:post][:author][:name]")
    assert_equal %(params.require_key("post").permit_keys(["title", "body"])), lower("params.require(:post).permit(:title, :body)")
    assert_equal %(params.require_key("post").permit_keys(["title"])), lower("params.expect(post: [:title])")
  end

  def test_request_params_in_actions
    assert_equal %(params.require_key("q").permit_keys(["term"])), lower("request.params.require(:q).permit(:term)")
    assert_equal %(param("id")), lower("request.params[:id]")
  end

  def test_redirects
    assert_equal "redirect_to(x, 303)", lower("redirect_to x, status: :see_other")
    assert_equal %(redirect_with_flash(x, 302, "Saved", "")), lower(%(redirect_to x, notice: "Saved"))
  end

  def test_head_and_json
    assert_equal "head(204)", lower("head :no_content")
    assert_equal %(render_json("{" + "\\"ok\\":" + (true).to_json + "}", 200)), lower("render json: { ok: true }")
    assert_equal "render_json((@post).to_json, 201)", lower("render json: @post, status: :created")
  end

  def test_query_forms
    assert_equal "Post.where_not(id: 1)", lower("Post.where.not(id: 1)")
    assert_equal "Post.all.pluck_title", lower("Post.all.pluck(:title)")
    assert_equal %(Post.order_sql("id DESC")), lower(%(Post.order("id DESC")))
    assert_equal "Post.where(id: 1).exists?", lower("Post.exists?(id: 1)")
  end

  def test_session_and_flash
    assert_equal %(session_set("user", 1)), lower("session[:user] = 1")
    assert_equal %(session_get("user")), lower("session[:user]")
    assert_equal %(session_delete("user")), lower("session.delete(:user)")
    assert_equal %(flash_now_set("notice", "x")), lower(%(flash.now[:notice] = "x"))
  end

  def test_controller_declarations_are_dropped
    assert_equal "\n", lower("before_action :x, only: [:show]\n")
  end

  def test_unknown_status
    error = assert_raises(Spinrail::CompileError) { lower("head :teapot_ish") }
    assert_match(/unknown status :teapot_ish/, error.message)
  end

  def test_turbo_frame_tag
    assert_equal %(("<turbo-frame id=\\"" + h(("x").to_s) + "\\"" + " src=\\"" + h((path).to_s) + "\\"" + ">" + "</turbo-frame>")),
                 lower(%(turbo_frame_tag "x", src: path), view: true, controller: false)
  end

  def test_views_turn_ivars_into_exposures
    assert_equal "out << iv_post.title", lower("out << @post.title", view: true, controller: false)
  end

  def test_views_cannot_assign_ivars
    assert_raises(Spinrail::CompileError) { lower("@x = 1", view: true, controller: false) }
  end
end
