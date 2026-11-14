class Actions::Stats::Show < Spinrail::Action
  def handle(request, response)
    latest = Entry.order(id: :desc).limit(5)
    response.render(view, count: Entry.count, latest: latest)
  end
end
