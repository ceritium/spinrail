require_relative "helper"

class ErbTest < CompilerTest
  def compile(source, **opts) = Rieles::Erb.compile(source, "t", **opts)

  def test_escapes_expressions
    assert_includes compile("<%= name %>"), "out << h((name).to_s)"
  end

  def test_raw_forms
    ruby = compile("<%== a %><%= raw b %><%= link_to x, y %>")
    assert_includes ruby, "out << (a).to_s"
    assert_includes ruby, "out << (b).to_s"
    assert_includes ruby, "out << (link_to x, y).to_s"
  end

  def test_code_lines_leave_no_blank_line
    ruby = compile("<ul>\n  <% items.each do |i| %>\n  <li></li>\n  <% end %>\n</ul>\n")
    refute_includes ruby, %("\\n  ")
  end

  def test_layout_yield_and_named_yield
    ruby = compile("<%= yield %><%= yield :title %>", layout: true)
    assert_includes ruby, "out << content"
    assert_includes ruby, %(out << content_for_get("title").to_s)
  end

  def test_block_expressions_are_code
    assert_includes compile("<%= form_with model: @post do |f| %><% end %>"), "  form_with model: @post do |f| # L1\n"
  end

  def test_unterminated_tag
    assert_raises(Rieles::CompileError) { compile("<%= oops") }
  end
end
