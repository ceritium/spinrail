require_relative "helper"
require_relative "../../runtime/html"

class HtmlTest < Minitest::Test
  def sanitize(html) = Spinrail::Html.sanitize(html)

  def test_keeps_the_safe_list
    assert_equal %(<p>Hi <b class="x">there</b><br><a href="https://example.com/a?b&c">link</a></p>),
                 sanitize(%(<p>Hi <b class="x" style="color:red">there</b><br/><a href="https://example.com/a?b&c" target="_blank">link</a></p>))
  end

  def test_drops_handlers_and_scripts
    assert_equal %(<img src="x"><b>text</b>), sanitize(%(<img src=x onerror="window.injected=true"><b>text</b>))
    assert_equal "after", sanitize("<script>bad()</script><style>p{}</style><iframe src=x></iframe>after")
    assert_equal "kept", sanitize(%(<unknown attr="1">kept</unknown><!-- comment -->))
  end

  def test_unsafe_urls
    ["javascript:alert(1)", "jav&#x61;script&colon;1", " java\tscript:1", "JAVASCRIPT:1", "data:text/html,x", "vbscript:x"].each do |url|
      assert_equal "<a>x</a>", sanitize(%(<a href="#{url}">x</a>)), url
    end
    ["/relative", "#anchor", "mailto:a@b.c", "http://x.y", "page?q=a:b"].each do |url|
      assert_equal %(<a href="#{url}">x</a>), sanitize(%(<a href="#{url}">x</a>)), url
    end
  end

  def test_attribute_values_cannot_break_out
    assert_equal %(<a title="a&quot;b&gt;">x</a>), sanitize(%(<a title='a"b>'>x</a>))
    assert_equal "a &lt;3 b", sanitize("a <3 b")
  end

  def test_plain_text
    assert_equal "Hello & world\nTwo é", Spinrail::Html.to_plain_text("<p>Hello &amp; <b>world</b></p><p>Two&nbsp;&#233;</p><script>x</script>")
  end
end
