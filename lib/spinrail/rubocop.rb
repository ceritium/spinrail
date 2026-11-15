require "rubocop"

# Cops for what spinel refuses or silently ignores, so the editor flags it
# before a build does. Loaded from an app's .rubocop.yml (`require:`).
module RuboCop
  module Cop
    module Spinel
      module Literal
        def literal_name?(node) = node && (node.sym_type? || node.str_type?)
      end

      class Eval < Base
        MSG = "spinel has no runtime parser: eval a String is refused. Use a block or plain code."
        RESTRICT_ON_SEND = %i[eval instance_eval class_eval module_eval].freeze

        def on_send(node)
          return if node.arguments.empty?
          return if %i[instance_eval class_eval module_eval].include?(node.method_name) && node.block_node
          add_offense(node)
        end
      end

      class MethodMissing < Base
        MSG = "spinel compiles calls to direct C calls and never dispatches `%<name>s`."

        def on_def(node)
          return unless %i[method_missing respond_to_missing?].include?(node.method_name)
          add_offense(node.loc.name, message: format(MSG, name: node.method_name))
        end
      end

      class DynamicName < Base
        include Literal

        MSG = "spinel resolves `%<name>s` at compile time: the name must be a literal Symbol or String."
        RESTRICT_ON_SEND = %i[send public_send __send__ define_method instance_variable_get
                              instance_variable_set const_get method].freeze

        def on_send(node)
          return if node.arguments.empty?
          return if literal_name?(node.first_argument)
          add_offense(node, message: format(MSG, name: node.method_name))
        end
      end

      class Reflection < Base
        MSG = "`%<name>s` needs a runtime spinel doesn't have."
        CONSTANTS = %i[ObjectSpace TracePoint].freeze
        CALLS = %i[set_trace_func callcc binding].freeze
        RESTRICT_ON_SEND = CALLS

        def on_const(node)
          return unless node.namespace.nil? && CONSTANTS.include?(node.short_name)
          return if node.parent&.send_type? && %i[define_finalizer undefine_finalizer].include?(node.parent.method_name)
          add_offense(node, message: format(MSG, name: node.short_name))
        end

        def on_send(node)
          return unless node.receiver.nil?
          # binding.local_variable_get(:x) with a literal name compiles.
          return if node.method?(:binding) && node.parent&.send_type? &&
                    node.parent.method?(:local_variable_get) && node.parent.first_argument&.sym_type?
          add_offense(node, message: format(MSG, name: node.method_name))
        end
      end
    end
  end
end
