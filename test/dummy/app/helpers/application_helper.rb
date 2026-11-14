module ApplicationHelper
  def page_title(text)
    content_for :title, text
    "<h1>" + h(text) + "</h1>"
  end

  def badge(text)
    ("<span class=\"badge\">" + h(text) + "</span>").html_safe
  end

  def shout(text)
    text.upcase + "!"
  end
end
