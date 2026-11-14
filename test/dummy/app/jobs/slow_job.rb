# Stands in for a job that waits on the network: spinrail jobs -c N overlaps them.
class SlowJob < ApplicationJob
  def perform(seconds)
    sleep(seconds.to_f)
  end
end
