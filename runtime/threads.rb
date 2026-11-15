# Compiled in only for `spinrail jobs -c N`, so the server binary never links
# spinel's threaded runtime. Each thread gets its own connection:
# Tep::SQLite has a single cursor per connection.
module Spinrail
  LOCK = Mutex.new
  DBS = [DB]

  def self.db_slot
    slot = Thread.current[:spinrail_db]
    slot.nil? ? 0 : slot.to_i
  end

  # Threads take connections 1..count; the main thread keeps 0 to heartbeat.
  def self.work_jobs_threaded(count)
    count.times { DBS << Database.new }
    Jobs.trap_signals
    id = Jobs.register(count)
    Jobs.prune(id)
    puts "spinrail: working jobs on " + count.to_s + " threads, queues " + Jobs.queues.join(",") + Jobs.host_suffix + " (Ctrl+C to stop)"
    $stdout.flush
    threads = []
    count.times do |i|
      threads << Thread.new(i + 1) do |slot|
        Thread.current[:spinrail_db] = slot
        Jobs.work(id, false)
      end
    end
    beaten = Spinrail.clock
    last = Jobs.recurring_slots
    until Jobs::STOP[0]
      sleep 0.2
      Jobs.schedule(last) if Jobs.recurring?
      next if Spinrail.clock - beaten < Jobs.heartbeat_interval
      Jobs.maintain(id)
      beaten = Spinrail.clock
    end
    threads.each(&:join)
    Jobs.stop(id)
  end
end
