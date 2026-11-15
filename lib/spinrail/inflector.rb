require "active_support"
require "active_support/inflector"

module Spinrail
  # Rails' own inflector: the build runs on CRuby, so names match Rails'.
  # App inflections (config/initializers/inflections.rb, ActiveSupport's own
  # calls) apply to this, so model, table and controller names follow them.
  module Inflector
    module_function

    def underscore(word) = ActiveSupport::Inflector.underscore(word)
    def camelize(word) = ActiveSupport::Inflector.camelize(word)
    def humanize(word) = ActiveSupport::Inflector.humanize(word)
    def pluralize(word) = ActiveSupport::Inflector.pluralize(word)
    def singularize(word) = ActiveSupport::Inflector.singularize(word)
    def tableize(class_name) = ActiveSupport::Inflector.tableize(class_name)

    # The build and the generators both inflect, so both load the app's
    # inflections first. Load re-runs on every build: ActiveSupport's own
    # calls are additive and idempotent enough (a repeated rule matches
    # first, a repeated acronym overwrites itself).
    def load_app(app_dir)
      file = File.join(app_dir, "config/initializers/inflections.rb")
      return unless File.exist?(file)
      load file
    rescue StandardError, ScriptError => e
      raise CompileError, "config/initializers/inflections.rb: #{e.message}"
    end
  end
end
