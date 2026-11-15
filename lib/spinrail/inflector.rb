require "active_support"
require "active_support/inflector"

module Spinrail
  # Rails' own inflector: the build runs on CRuby, so names match Rails'.
  module Inflector
    module_function

    def underscore(word) = ActiveSupport::Inflector.underscore(word)
    def camelize(word) = ActiveSupport::Inflector.camelize(word)
    def humanize(word) = ActiveSupport::Inflector.humanize(word)
    def pluralize(word) = ActiveSupport::Inflector.pluralize(word)
    def singularize(word) = ActiveSupport::Inflector.singularize(word)
    def tableize(class_name) = ActiveSupport::Inflector.tableize(class_name)
  end
end
