require "prism"
require "fileutils"
require "json"
require "cgi/escape"
require "digest"
require "yaml"
require "zlib"

module Spinrail
  class CompileError < StandardError; end

  RUNTIME = File.expand_path("../runtime/spinrail.rb", __dir__)

  def self.literal(node)
    case node
    when Prism::StringNode then node.unescaped
    when Prism::SymbolNode then node.unescaped.to_sym
    when Prism::IntegerNode, Prism::FloatNode then node.value
    when Prism::NilNode then nil
    when Prism::TrueNode then true
    when Prism::FalseNode then false
    when Prism::ArrayNode then node.elements.map { |e| literal(e) }
    when Prism::HashNode, Prism::KeywordHashNode
      node.elements.to_h { |a| [literal(a.key), literal(a.value)] }
    else raise CompileError, "line #{node.location.start_line}: expected a literal, got `#{node.slice}`"
    end
  end

  # Actions::Stats::Show -> "stats.show", the key that pairs an action
  # with its view (Views::Stats::Show) and template (stats/show.html.erb).
  def self.class_key(name, namespace)
    return nil unless name.start_with?("#{namespace}::")
    name.delete_prefix("#{namespace}::").split("::").map { |s| Inflector.underscore(s) }.join(".")
  end

  def self.class_name(key, namespace)
    "#{namespace}::#{key.split('.').map { |s| Inflector.camelize(s) }.join('::')}"
  end

  # Splits a call's arguments into positional nodes and a {Symbol => node} hash.
  def self.call_args(node)
    args = (node.arguments&.arguments || []).dup
    kw = args.last.is_a?(Prism::KeywordHashNode) ? args.pop : nil
    keywords = (kw&.elements || []).to_h { |a| [literal(a.key), a.value] }
    [args, keywords]
  end

  def self.parse(source, file)
    result = Prism.parse(source)
    if result.failure?
      e = result.errors.first
      raise CompileError, "#{file}:#{e.location.start_line}: #{e.message}"
    end
    result.value
  end
end

require_relative "spinrail/inflector"
require_relative "spinrail/lowering"
require_relative "spinrail/routes"
require_relative "spinrail/schema"
require_relative "spinrail/migrations"
require_relative "spinrail/models"
require_relative "spinrail/views"
require_relative "spinrail/build"
require_relative "spinrail/generators"
require_relative "spinrail/cli"
