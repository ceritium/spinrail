module Spinrail
  # delegate :host, :protocol, to: :request, prefix: true, allow_nil: true
  # as plain defs. A delegated method takes no arguments (a writer, one):
  # spinel has no `...` forwarding to type them through.
  module Delegation
    OPTIONS = %i[to prefix allow_nil].freeze

    def self.delegate?(node) =
      node.is_a?(Prism::CallNode) && node.receiver.nil? && node.name == :delegate && Spinrail.call_args(node)[1].key?(:to)

    # [[name, params], ...] and the Ruby that defines them.
    def self.expand(node, file)
      names, kw = Spinrail.call_args(node)
      where = "#{file}:#{node.location.start_line}"
      unknown = kw.keys - OPTIONS
      raise CompileError, "#{where}: unsupported delegate option #{unknown.first}" if unknown.any?
      target = Spinrail.literal(kw[:to]).to_s
      raise CompileError, "#{where}: delegate to: takes a method or @ivar name" unless target.match?(/\A@?[a-z_]\w*\z/)
      prefix = kw[:prefix] ? Spinrail.literal(kw[:prefix]) : false
      prefix = target.delete_prefix("@") if prefix == true
      target = "self.class" if target == "class"
      allow_nil = kw[:allow_nil] ? Spinrail.literal(kw[:allow_nil]) == true : false
      raise CompileError, "#{where}: delegate needs method names" if names.empty?
      defs = names.map do |n|
        method = Spinrail.literal(n).to_s
        name = prefix ? "#{prefix}_#{method}" : method
        call = allow_nil ? "#{target}&.#{method}" : "#{target}.#{method}"
        if method.end_with?("=")
          [[name, "value"], "def #{name}(value)\n  #{call.delete_suffix('=')} = value\nend"]
        else
          [[name, ""], "def #{name}\n  #{call}\nend"]
        end
      end
      [defs.map(&:first), defs.map(&:last).join("\n\n")]
    end
  end
end
