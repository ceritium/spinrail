require "strscan"

module Rieles
  # Compiles ERB into a Ruby method body. Unlike tep's ERB, templates are
  # methods on the controller, so they read its typed ivars and can loop.
  # `<%= %>` escapes; `<%== %>`, raw(...), render and yield don't.
  module Erb
    module_function

    # Helpers that return markup; their output isn't escaped again.
    HTML_HELPERS = /\A(csrf_meta_tags|link_to|button_to|hidden_field_tag)\b/

    # log_as: template name for the request log; partials pass nil.
    def compile(source, signature, layout: false, log_as: nil)
      tokens = tokenize(source)
      trim_code_lines(tokens)
      body = tokens.map { |kind, text| emit(kind, text, layout) }.join
      return "def #{signature}\n  out = +\"\"\n#{body}  out\nend\n" unless log_as
      "def #{signature}\n  rieles_t0 = Rieles.log.render_start\n  out = +\"\"\n#{body}" \
        "  Rieles.log.render_end(#{log_as.inspect}, rieles_t0)\n  out\nend\n"
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
        kind = if s.scan(/==/) then :raw
               elsif s.scan(/=/) then :expr
               elsif s.scan(/#/) then :comment
               else :code
               end
        code = s.scan_until(/-?%>/) or raise CompileError, "unterminated <% tag"
        tokens << [kind, code.sub(/-?%>\z/, "")]
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

    def emit(kind, text, layout)
      code = text.strip
      case kind
      when :text then text.empty? ? "" : "  out << #{text.inspect}\n"
      when :comment then ""
      when :code then "  #{code}\n"
      when :raw then "  out << (#{code}).to_s\n"
      when :expr
        if layout && code == "yield" then "  out << content\n"
        elsif code.match?(HTML_HELPERS) then "  out << (#{code}).to_s\n"
        elsif code.match?(/\Araw\b/) then "  out << (#{code.sub(/\Araw\s*/, '')}).to_s\n"
        elsif code.match?(/\Arender\b/) then "  out << (#{code})\n"
        else "  out << h((#{code}).to_s)\n"
        end
      end
    end
  end
end
