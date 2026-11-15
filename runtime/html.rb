module Spinrail
  # Action Text's safe list, applied when rich text is rendered: unknown tags
  # go (their text stays), script-like ones go with their content, and only
  # listed attributes with safe URLs survive.
  module Html
    TAGS = %w[a abbr acronym address b big blockquote br cite code dd del dfn div dl dt em figcaption figure
              h1 h2 h3 h4 h5 h6 hr i img ins kbd li mark ol p pre s samp small span strong sub sup
              table tbody td th thead tr time tt u ul var action-text-attachment].freeze
    ATTRS = %w[abbr alt cite class datetime height href lang name src title width xml:lang
               content-type url filename filesize previewable presentation caption sgid content].freeze
    URL_ATTRS = %w[href src cite url].freeze
    DROP = %w[script style iframe object embed template noscript textarea select option title svg math].freeze
    BLOCKS = %w[p div br li h1 h2 h3 h4 h5 h6 blockquote pre tr figure figcaption ul ol table hr].freeze
    PROTOCOLS = %w[http https mailto tel].freeze

    def self.sanitize(html)
      out = +""
      i = 0
      n = html.length
      skip = ""
      while i < n
        lt = html.index("<", i)
        if lt.nil?
          out << html[i, n - i] if skip.empty?
          break
        end
        out << html[i, lt - i] if skip.empty? && lt > i
        if html[lt, 4] == "<!--"
          close = html.index("-->", lt + 4)
          i = close.nil? ? n : close + 3
          next
        end
        gt = Html.tag_end(html, lt + 1)
        unless gt > 0 && Html.tag_start?(html, lt + 1)
          out << "&lt;" if skip.empty?
          i = lt + 1
          next
        end
        tag = html[lt + 1, gt - lt - 1]
        i = gt + 1
        closing = tag.start_with?("/")
        name = Html.tag_name(tag, closing ? 1 : 0)
        unless skip.empty?
          skip = "" if closing && name == skip
          next
        end
        if DROP.include?(name)
          skip = name unless closing || tag.end_with?("/")
          next
        end
        next unless TAGS.include?(name)
        out << (closing ? "</" + name + ">" : "<" + name + Html.safe_attrs(tag, name.length) + ">")
      end
      out
    end

    def self.to_plain_text(html)
      out = +""
      i = 0
      n = html.length
      skip = ""
      while i < n
        lt = html.index("<", i)
        if lt.nil?
          out << html[i, n - i] if skip.empty?
          break
        end
        out << html[i, lt - i] if skip.empty? && lt > i
        gt = Html.tag_end(html, lt + 1)
        if gt < 0
          out << "<" if skip.empty?
          i = lt + 1
          next
        end
        tag = html[lt + 1, gt - lt - 1]
        i = gt + 1
        closing = tag.start_with?("/")
        name = Html.tag_name(tag, closing ? 1 : 0)
        unless skip.empty?
          skip = "" if closing && name == skip
          next
        end
        if DROP.include?(name) && !closing && !tag.end_with?("/")
          skip = name
          next
        end
        out << "\n" if BLOCKS.include?(name) && (closing || name == "br") && !out.empty? && !out.end_with?("\n")
      end
      Html.decode(out).strip
    end

    def self.tag_start?(html, at)
      c = html[at, 1]
      c == "/" || c == "!" || (c >= "a" && c <= "z") || (c >= "A" && c <= "Z")
    end

    # The closing > of a tag, skipping quoted attribute values.
    def self.tag_end(html, from)
      quote = ""
      j = from
      n = html.length
      while j < n
        c = html[j, 1]
        if quote.empty?
          return j if c == ">"
          quote = c if c == "\"" || c == "'"
        elsif c == quote
          quote = ""
        end
        j += 1
      end
      -1
    end

    def self.tag_name(tag, from)
      j = from
      n = tag.length
      while j < n
        c = tag[j, 1]
        break unless (c >= "a" && c <= "z") || (c >= "A" && c <= "Z") || (c >= "0" && c <= "9") || c == "-" || c == ":"
        j += 1
      end
      tag[from, j - from].downcase
    end

    def self.space?(c) = c == " " || c == "\n" || c == "\t" || c == "\r" || c == "\f"

    def self.safe_attrs(tag, from)
      out = +""
      j = from
      n = tag.length
      while j < n
        while j < n && (Html.space?(tag[j, 1]) || tag[j, 1] == "/")
          j += 1
        end
        break if j >= n
        s = j
        while j < n && tag[j, 1] != "=" && tag[j, 1] != "/" && !Html.space?(tag[j, 1])
          j += 1
        end
        if j == s
          j += 1
          next
        end
        name = tag[s, j - s].downcase
        k = j
        k += 1 while k < n && Html.space?(tag[k, 1])
        value = ""
        given = false
        if k < n && tag[k, 1] == "="
          given = true
          j = k + 1
          j += 1 while j < n && Html.space?(tag[j, 1])
          q = j < n ? tag[j, 1] : ""
          if q == "\"" || q == "'"
            e = tag.index(q, j + 1)
            e = n if e.nil?
            value = tag[j + 1, e - j - 1]
            j = e + 1
          else
            s2 = j
            j += 1 while j < n && !Html.space?(tag[j, 1])
            value = tag[s2, j - s2]
          end
        end
        next unless ATTRS.include?(name)
        next if URL_ATTRS.include?(name) && !Html.safe_url?(value)
        out << " " + name + (given ? "=\"" + value.gsub("\"", "&quot;").gsub("<", "&lt;").gsub(">", "&gt;") + "\"" : "")
      end
      out
    end

    # Browsers decode entities and drop control characters and spaces before
    # reading a URL's scheme, so this does too.
    def self.safe_url?(value)
      url = +""
      Html.decode(value).each_char { |c| url << c if c.ord > 32 }
      cut = url.length
      %w[/ ? #].each do |stop|
        at = url.index(stop)
        cut = at if !at.nil? && at < cut
      end
      scheme = url[0, cut].downcase
      return false if scheme.include?("&")
      colon = scheme.index(":")
      colon.nil? || PROTOCOLS.include?(scheme[0, colon])
    end

    NAMED = { "amp" => "&", "lt" => "<", "gt" => ">", "quot" => "\"", "apos" => "'", "nbsp" => " ",
              "colon" => ":", "tab" => "\t", "newline" => "\n", "sol" => "/", "num" => "#", "quest" => "?" }.freeze

    # Named and numeric character references; unknown ones stay as written.
    def self.decode(text)
      return text unless text.include?("&")
      out = +""
      i = 0
      n = text.length
      while i < n
        amp = text.index("&", i)
        if amp.nil?
          out << text[i, n - i]
          break
        end
        out << text[i, amp - i]
        j = amp + 1
        if j < n && text[j, 1] == "#"
          j += 1
          hex = j < n && (text[j, 1] == "x" || text[j, 1] == "X")
          j += 1 if hex
          s = j
          j += 1 while j < n && Html.digit?(text[j, 1], hex)
          if j > s
            code = hex ? text[s, j - s].to_i(16) : text[s, j - s].to_i
            out << (code > 0 && code < 0x110000 ? [code].pack("U") : "�")
            j += 1 if j < n && text[j, 1] == ";"
            i = j
            next
          end
        else
          s = j
          j += 1 while j < n && ((text[j, 1] >= "a" && text[j, 1] <= "z") || (text[j, 1] >= "A" && text[j, 1] <= "Z"))
          word = text[s, j - s]
          if NAMED.key?(word)
            out << NAMED[word]
            j += 1 if j < n && text[j, 1] == ";"
            i = j
            next
          end
        end
        out << "&"
        i = amp + 1
      end
      out
    end

    def self.digit?(c, hex) = (c >= "0" && c <= "9") || (hex && ((c >= "a" && c <= "f") || (c >= "A" && c <= "F")))
  end
end
