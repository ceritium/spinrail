# One at a time per group.
class SerialJob < ApplicationJob
  limits_concurrency to: 1, key: ->(group) { group }, duration: 1.minute

  def perform(group)
    raise ArgumentError, "bad group" if group == "bad"
    sleep(group == "slow" ? 5.0 : 0.2)
  end
end
