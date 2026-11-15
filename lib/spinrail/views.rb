require "strscan"

module Spinrail
  # Compiles ERB into a Ruby method body. Unlike tep's ERB, templates are
  # methods on the controller, so they read its typed ivars and can loop.
  # `<%= %>` escapes; `<%== %>`, raw(...), render and yield don't.
  module Erb
    module_function

    # Helpers that return markup; their output isn't escaped again.
    HTML_HELPERS = /\A(turbo_frame_tag|turbo_stream_from|turbo_stream\.\w+|paginate|csrf_meta_tags|content_for|simple_format|
                      stylesheet_link_tag|javascript_include_tag|javascript_importmap_tags|image_tag|link_to|button_to|
                      \w+\.(label|\w+_field|text_?area|rich_text_?area|check_?box|select|collection_select|submit))\b/x
    BLOCK = /\bdo\s*(\|[^|]*\|)?\z/

    # log_as: template name for the request log; partials pass nil.
    # raw: helper names whose output is html_safe.
    # escape: false for .text.erb templates.
    def compile(source, signature, layout: false, log_as: nil, raw: [], escape: true, rich: [])
      tokens = tokenize(source)
      trim_code_lines(tokens)
      raw_call = raw.empty? ? nil : /\A(#{raw.map { |r| Regexp.escape(r) }.join('|')})\b/
      rich_call = rich.empty? ? nil : /\.(#{rich.map { |r| Regexp.escape(r) }.join('|')})\z/
      body = tokens.map { |kind, text, line| tag_line(emit(kind, text, layout, raw_call, rich_call), kind, line) }.join
      body = body.gsub(/^  out << h\(\((.*)\)\.to_s\)( # L\d+)?$/) { "  out << (#{$1}).to_s#{$2}" } unless escape
      return "def #{signature}\n  out = +\"\"\n#{body}  out\nend\n" unless log_as
      "def #{signature}\n  spinrail_t0 = Spinrail.log.render_start\n  out = +\"\"\n#{body}" \
        "  Spinrail.log.render_end(#{log_as.inspect}, spinrail_t0)\n  out\nend\n"
    end

    def tokenize(source)
      s = StringScanner.new(source)
      tokens = []
      until s.eos?
        text = s.scan_until(/<%/)
        unless text
          tokens << [:text, s.rest]
          break
        end
        tokens << [:text, text[0...-2]]
        line = s.string.byteslice(0, s.pos).count("\n") + 1
        kind = if s.scan("==") then :raw
               elsif s.scan("=") then :expr
               elsif s.scan("#") then :comment
               else :code
               end
        code = s.scan_until(/-?%>/) or raise CompileError, "unterminated <% tag"
        tokens << [kind, code.sub(/-?%>\z/, ""), line]
      end
      tokens
    end

    # A <% %> tag alone on its line leaves no blank line behind.
    def trim_code_lines(tokens)
      tokens.each_with_index do |(kind, _), i|
        next unless %i[code comment].include?(kind)
        before = i.positive? ? tokens[i - 1] : nil
        after = tokens[i + 1]
        next unless before.nil? || (before[0] == :text && before[1].match?(/(\A|\n)[ \t]*\z/))
        next unless after.nil? || (after[0] == :text && after[1].match?(/\A[ \t]*\n/))
        before[1] = before[1].sub(/[ \t]*\z/, "") if before
        after[1] = after[1].sub(/\A[ \t]*\n/, "") if after
      end
    end

    # "# L12" after the code of a tag: build errors map back to the .erb line.
    def tag_line(ruby, kind, line)
      return ruby if kind == :text || ruby.empty?
      ruby.sub(/\n\z/, " # L#{line}\n")
    end

    def emit(kind, text, layout, raw_call = nil, rich_call = nil)
      code = text.strip
      case kind
      when :text then text.empty? ? "" : "  out << #{text.inspect}\n"
      when :comment then ""
      when :code then "  #{code}\n"
      when :raw then "  out << (#{code}).to_s\n"
      when :expr
        if layout && code == "yield" then "  out << content\n"
        elsif (name = code[/\Ayield[\s(]+:(\w+)\)?\z/, 1]) then "  out << content_for_get(#{name.inspect}).to_s\n"
        elsif code.match?(BLOCK) then "  #{code}\n"
        elsif code.match?(HTML_HELPERS) || (raw_call && code.match?(raw_call)) then "  out << (#{code}).to_s\n"
        elsif code.match?(/\Araw\b/) then "  out << (#{code.sub(/\Araw\s*/, '')}).to_s\n"
        elsif code.match?(/\Arender\b/) then "  out << (#{code})\n"
        elsif rich_call && code.match?(rich_call) then "  out << (#{code}).to_html\n"
        else "  out << h((#{code}).to_s)\n"
        end
      end
    end
  end
end
