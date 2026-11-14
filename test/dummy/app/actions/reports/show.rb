class Actions::Reports::Show < Spinrail::Action
  def handle(request, response)
    halt 403, "no access" if request.params[:key] == "bad"
    halt :not_found if request.params[:key] == "gone"
    response.status = 202 if request.params[:key] == "later"
    response.render(view, posts: Post.order(id: :asc), title: "Report")
  end
end
