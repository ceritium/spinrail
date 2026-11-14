module ApplicationHelper
  def page_title(text)
    content_for :title, text
    "<h1>" + h(text) + "</h1>"
  end

  def shout(text)
    text.upcase + "!"
  end
end
