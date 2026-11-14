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

  def self.work_jobs_threaded(count)
    Spinrail.jobs_schema
    (count - 1).times { DBS << Database.new }
    puts "spinrail: working jobs on " + count.to_s + " threads (Ctrl+C to stop)"
    $stdout.flush
    threads = []
    count.times do |i|
      threads << Thread.new(i) do |slot|
        Thread.current[:spinrail_db] = slot
        loop { sleep 1 unless Spinrail.work_job }
      end
    end
    threads.each(&:join)
  end
end
