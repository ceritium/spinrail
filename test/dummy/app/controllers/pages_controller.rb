class PagesController < ApplicationController
  def file
    render plain: "file " + params[:path] + " " + files_path("a/b.txt")
  end

  def number
    render plain: "number " + params[:n]
  end

  def word
    render plain: "word " + params[:word]
  end

  # Spinrail::HTTP against this same server, so the test exercises the
  # compiled client end to end (Tep::Http only exists inside the binary).
  def http_probe
    res = Spinrail::HTTP.get("http://" + request.host + "/plain", nil, true)
    render plain: "status=" + res.status.to_s + " body=" + res.body
  end

  def http_probe_json
    data = Spinrail::HTTP.get_json("http://" + request.host + "/widgets")
    render plain: "ok=" + data["ok"].to_s + " tags=" + data["tags"].length.to_s
  end

  def http_probe_redirect
    res = Spinrail::HTTP.get("http://" + request.host + "/http/redirect_target", nil, true)
    render plain: "status=" + res.status.to_s + " body=" + res.body
  end

  def http_redirect_target
    redirect_to "/plain"
  end

  def badge
    @label = params[:label]
    expires_in 30.minutes, public: true
    render formats: :svg
  end

  def mark
    send_file Rails.root.join("app/views/pages/mark.svg"), content_type: "image/svg+xml", disposition: :inline
  end

  def home
    @posts = Post.order(id: :asc)
    @post = Post.first
  end
end
