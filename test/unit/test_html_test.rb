require_relative "helper"
require_relative "../../lib/spinrail/test_html"

class TestHTMLTest < CompilerTest
  HTML = <<~HTML
    <ul class="entries"><li class="item new">One &amp; two</li><li class="item">Three<br></li></ul>
    <form action="/x"><input name="post[title]" value="Hi"><p id="note">Note</p></form>
  HTML

  def select(selector) = Spinrail::TestHTML.select(Spinrail::TestHTML.parse(HTML), selector)

  def test_selectors
    assert_equal ["One & two", "Three"], select("ul.entries li").map(&:text)
    assert_equal ["One & two"], select("li.item.new").map(&:text)
    assert_equal ["Note"], select("form #note").map(&:text)
    assert_equal 1, select("input[name='post[title]']").size
    assert_equal 1, select("input[value=Hi]").size
    assert_empty select("ul p")
    assert_equal 1, select("form p[id='note'], ul.missing").size
    assert_equal 1, select("input[value='Hi'][name='post[title]']").size
  end
end
