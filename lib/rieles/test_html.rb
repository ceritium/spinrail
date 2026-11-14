module Rieles
  # Just enough HTML parsing for assert_select: tags, attributes, text, and
  # selectors made of tag, .class, #id and [attr=value] with descendant
  # combinators.
  module TestHTML
    VOID = %w[area base br col embed hr img input link meta source track wbr].freeze

    Node = Struct.new(:tag, :attrs, :children, :parent) do
      def text = children.map { |c| c.is_a?(String) ? c : c.text }.join
      def classes = attrs.fetch("class", "").split
      def elements = children.grep(Node)

      def descendants
        elements.flat_map { |e| [e, *e.descendants] }
      end
    end

    module_function

    def parse(html)
      root = Node.new("#root", {}, [], nil)
      current = root
      html.scan(%r{<!--.*?-->|<(/?)([a-zA-Z][\w-]*)([^>]*)>|[^<]+|<}m) do |close, tag, rest|
        token = Regexp.last_match(0)
        if tag.nil?
          current.children << unescape(token) unless token.start_with?("<!--")
        elsif close == "/"
          node = current
          node = node.parent while node.parent && node.tag != tag.downcase
          current = node.parent || root if node.tag == tag.downcase
        else
          node = Node.new(tag.downcase, attributes(rest), [], current)
          current.children << node
          current = node unless VOID.include?(node.tag) || rest.end_with?("/")
        end
      end
      root
    end

    def attributes(source)
      source.scan(/([\w:-]+)(?:\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s>]+)))?/).to_h do |name, dq, sq, bare|
        [name.downcase, unescape(dq || sq || bare || "")]
      end
    end

    def unescape(text)
      text.gsub("&lt;", "<").gsub("&gt;", ">").gsub("&quot;", '"').gsub("&#39;", "'").gsub("&amp;", "&")
    end

    def select(root, selector)
      selector.scan(/(?:\[(?:"[^"]*"|'[^']*'|[^\]"'])*\]|[^,\[])+/).flat_map do |group|
        steps = group.strip.scan(/(?:\[(?:"[^"]*"|'[^']*'|[^\]"'])*\]|[^\s\[])+/)
        steps.reduce([root]) do |scope, step|
          scope.flat_map(&:descendants).uniq.select { |n| match?(n, step) }
        end
      end.uniq
    end

    def match?(node, step)
      tag = step[/\A[a-zA-Z][\w-]*/]
      return false if tag && node.tag != tag.downcase
      plain = step.gsub(/\[[^\]]*(?:\][^\[]*)?\]/, "")
      return false unless plain.scan(/\.([\w-]+)/).flatten.all? { |c| node.classes.include?(c) }
      id = plain[/#([\w-]+)/, 1]
      return false if id && node.attrs["id"] != id
      step.scan(/\[([\w:-]+)(?:=(?:"([^"]*)"|'([^']*)'|([^\]]*)))?\]/).all? do |name, dq, sq, bare|
        value = dq || sq || bare
        node.attrs.key?(name) && (value.nil? || node.attrs[name] == value)
      end
    end
  end
end
