# A second one while the first waits is dropped.
class OnceJob < ApplicationJob
  limits_concurrency key: ->(name) { "once-" + name }, on_conflict: :discard

  def perform(name)
  end
end
