class BrokenJob < ApplicationJob
  def perform(arg)
    raise ArgumentError, "broken " + arg
  end
end
