require_relative "helper"

class LoweringTest < CompilerTest
  def test_params
    assert_equal %(param("id")), lower("params[:id]")
    assert_equal %(param("post[author][name]")), lower("params[:post][:author][:name]")
    assert_equal %(params.require_key("post").permit_keys(["title", "body"])), lower("params.require(:post).permit(:title, :body)")
    assert_equal %(params.require_key("post").permit_keys(["title"])), lower("params.expect(post: [:title])")
    assert_equal %(params.array("tag_ids")), lower("params.fetch(:tag_ids, [])")
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
    assert_equal %(Post.order(created_at: :asc, id: :asc)), lower(%(Post.order(:created_at, :id)))
    assert_equal "Post.where(id: 1).exists?", lower("Post.exists?(id: 1)")
  end

  def test_session_and_flash
    assert_equal %(session_set("user", 1)), lower("session[:user] = 1")
    assert_equal %(session_get("user")), lower("session[:user]")
    assert_equal %(session_delete("user")), lower("session.delete(:user)")
    assert_equal %(flash_now_set("notice", "x")), lower(%(flash.now[:notice] = "x"))
  end

  def test_cookie_options
    assert_equal %(cookie_set_permanent_signed("t", x)), lower("cookies.signed.permanent[:t] = x")
    assert_equal %(cookie_write("t", s.token, true, true, true, "Lax")),
                 lower("cookies.signed.permanent[:t] = { value: s.token, httponly: true, same_site: :lax }")
    assert_equal %(cookie_write("t", x, false, false, false, "Strict")), lower("cookies[:t] = { value: x, same_site: :strict }")
    assert_raises(Spinrail::CompileError) { lower("cookies[:t] = { value: x, domain: :all }") }
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

  def test_raw_sql
    assert_equal %(Post.where_sql("created_at < ?", [Spinrail.sql_text(t)])), lower(%(Post.where("created_at < ?", t)))
    assert_equal %(Post.where_sql("draft", Spinrail.no_binds)), lower(%(Post.where("draft")))
    assert_equal %(Post.with_joins(["sql:join x on x.id = posts.id"])), lower(%(Post.joins("join x on x.id = posts.id")))
    assert_equal %(Spinrail.execute(Spinrail.sanitize_sql("delete from x where id = ?", [Spinrail.sql_text(id)]))),
                 lower(%(self.class.connection.execute self.class.sanitize_sql(["delete from x where id = ?", id])))
  end

  def test_button_to_params
    out = lower(%(button_to path, params: { ids: [user.id], kind: "x" } do\nend), view: true, controller: false)
    assert_includes out, %(form_open((path).to_s, "post", " class=\\"button_to\\"") + "<input type=\\"hidden\\" name=\\"" + h("ids[]") + "\\" value=\\"" + h((user.id).to_s) + "\\">" + "<input type=\\"hidden\\" name=\\"" + h("kind") + "\\" value=\\"" + h(("x").to_s) + "\\">" + "<button)
  end

  def test_button_to_with_a_block
    out = lower(%(button_to path, method: :delete, class: "b" do\n  out << "x"\nend), view: true, controller: false)
    assert_includes out, %(out << form_open((path).to_s, "delete", " class=\\"button_to\\"") + "<button type=\\"submit\\"" + " class=\\"b\\"" + ">")
    assert_includes out, %(out << "</button></form>")
  end

  def test_image_tag_size
    assert_includes lower(%(image_tag "a.svg", size: 20, class: "x"), view: true), %( width=\\"20\\" height=\\"20\\")
    assert_includes lower(%(image_tag "a.svg", size: "20x30"), view: true), %( width=\\"20\\" height=\\"30\\")
  end

  def test_block_pass_skips_the_n_plus_one_check
    assert_equal "threads.each(&:join)", lower("threads.each(&:join)")
  end

  def test_job_calls
    assert_equal %(Spinrail::Jobs.enqueue("ShoutJob", [(id).to_s, ("x").to_s], "", -1, "")), lower(%(ShoutJob.perform_later(id, "x")))
    assert_equal %(Spinrail::Jobs.enqueue("PingJob", Spinrail.no_binds, "", -1, "")), lower("PingJob.perform_later")
    assert_equal %(Spinrail::Jobs.enqueue("ShoutJob", [(id).to_s], (:low).to_s, (5).to_i, Spinrail.format_time(Time.now + (5.minutes)))),
                 lower("ShoutJob.set(queue: :low, priority: 5, wait: 5.minutes).perform_later(id)")
    assert_equal %(Spinrail::Jobs.enqueue("ShoutJob", [(id).to_s], "", -1, Spinrail.format_time(Spinrail.to_time(t)))),
                 lower("ShoutJob.set(wait_until: t).perform_later(id)")
    assert_equal "ShoutJob.new.perform((id).to_s)", lower("ShoutJob.perform_now(id)")
    assert_raises(Spinrail::CompileError) { lower("ShoutJob.set(retry: 1).perform_later(id)") }
  end
end
