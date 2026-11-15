class FlakyError < StandardError; end

# Fails until its third execution; each try leaves an author behind.
class FlakyJob < ApplicationJob
  retry_on FlakyError, wait: 0, attempts: 3
  discard_on ArgumentError

  def perform(name)
    raise ArgumentError, "unwanted" if name == "unwanted"
    tries = Author.where(name: name).count
    Author.create!(name: name, email: name + tries.to_s + "@example.com")
    raise FlakyError, "try " + (tries + 1).to_s if tries < 2
  end
end
