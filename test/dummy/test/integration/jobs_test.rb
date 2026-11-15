class InlineJobsTest < Spinrail::IntegrationTest
  def test_jobs_run_inline_in_tests
    get "/models/seed"
    get "/models/shout"
    get "/models/authors"
    assert_equal "Ana!,Bea", response.body
  end

  def test_retries_and_discards_inline
    get "/models/seed"
    get "/models/shout?flaky=1"
    get "/models/authors"
    assert_equal "Ana!,Bea,flaky,flaky,flaky", response.body
  end

  def test_scheduled_jobs_run_right_away_in_tests
    get "/models/seed"
    get "/models/enqueue"
    get "/models/authors"
    assert_equal "Ana,Bea,later,low,d5,d0", response.body
  end
end

class QueuedJobsTest < Spinrail::IntegrationTest
  server_env "SPINRAIL_JOBS_INLINE" => "0"

  def test_a_worker_drains_the_queue
    get "/models/seed"
    get "/models/shout?broken=1&flaky=1"
    get "/models/authors"
    assert_equal "Ana,Bea", response.body

    log = File.join(Dir.tmpdir, "spinrail-jobs-#{Process.pid}.log")
    worker = Process.spawn({ "DATABASE_PATH" => database_path, "DATABASE_URL" => database_path, "SPINRAIL_JOBS" => "1", "SPINRAIL_ENV" => "test",
                             "SPINRAIL_JOBS_INLINE" => "0" }, ENV.fetch("SPINRAIL_BINARY"), out: log, err: log)
    50.times do
      get "/models/authors"
      break if response.body.end_with?("flaky,flaky,flaky")
      sleep 0.1
    end
    assert_equal "Ana!,Bea,flaky,flaky,flaky", response.body
    sleep 0.3
    assert_includes File.read(log), "Performed ShoutJob"
    assert_includes File.read(log), "Failed BrokenJob"
    assert_equal 2, File.read(log).scan(/Failed FlakyJob #\d+: try \d \(retrying in 0s\)/).size, File.read(log)
    assert_includes File.read(log), "Discarded FlakyJob"
    assert_equal 1, File.read(log).scan("Performed FlakyJob").size
  ensure
    Process.kill("KILL", worker) if worker
    Process.wait(worker) if worker
  end
end

class QueuesTest < Spinrail::IntegrationTest
  server_env "SPINRAIL_JOBS_INLINE" => "0"

  # Queues in the order given, then priority (lower first); "later" waits 2s.
  def test_queues_priorities_and_scheduled_jobs
    get "/models/seed"
    get "/models/enqueue"
    enqueued = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    log = File.join(Dir.tmpdir, "spinrail-queues-#{Process.pid}.log")
    worker = Process.spawn({ "DATABASE_PATH" => database_path, "DATABASE_URL" => database_path, "SPINRAIL_JOBS" => "1", "SPINRAIL_ENV" => "test",
                             "SPINRAIL_JOBS_INLINE" => "0", "SPINRAIL_JOBS_QUEUES" => "default,low" },
                           ENV.fetch("SPINRAIL_BINARY"), out: log, err: log)
    50.times do
      get "/models/authors"
      break if response.body.end_with?(",low")
      sleep 0.1
    end
    assert_equal "Ana,Bea,d0,d5,low", response.body
    50.times do
      get "/models/authors"
      break if response.body.end_with?(",later")
      sleep 0.1
    end
    assert_equal "Ana,Bea,d0,d5,low,later", response.body
    assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - enqueued, :>=, 1.5
  ensure
    Process.kill("KILL", worker) if worker
    Process.wait(worker) if worker
  end
end

module WorkerHelpers
  def worker(log, env = {})
    Process.spawn({ "DATABASE_PATH" => database_path, "DATABASE_URL" => database_path, "SPINRAIL_JOBS" => "1", "SPINRAIL_ENV" => "test",
                    "SPINRAIL_JOBS_INLINE" => "0" }.merge(env), ENV.fetch("SPINRAIL_BINARY"), out: log, err: log)
  end

  def jobs(command)
    IO.popen({ "DATABASE_PATH" => database_path, "DATABASE_URL" => database_path, "SPINRAIL_JOBS" => command, "SPINRAIL_ENV" => "test" },
             [ENV.fetch("SPINRAIL_BINARY")], &:read).lines.map(&:strip).reject { |l| l.start_with?("SQL") || l.empty? }
  end

  def status = jobs("status").first

  def wait_for(log, text)
    50.times do
      break if File.exist?(log) && File.read(log).include?(text)
      sleep 0.1
    end
    assert_includes File.read(log), text
  end
end

class ProcessesTest < Spinrail::IntegrationTest
  include WorkerHelpers

  server_env "SPINRAIL_JOBS_INLINE" => "0"

  # TERM lets the job at hand finish and hands the queued one back.
  def test_term_finishes_the_job_at_hand
    get "/models/seed"
    get "/models/shout?slow=2"
    log = File.join(Dir.tmpdir, "spinrail-term-#{Process.pid}.log")
    pid = worker(log)
    wait_for(log, "Performed ShoutJob")
    sleep 0.2
    Process.kill("TERM", pid)
    Process.wait(pid)
    assert_equal 0, $?.exitstatus
    assert_equal 1, File.read(log).scan("Performed SlowJob").size
    assert_includes File.read(log), "stopped working jobs"
    assert_equal "ready=1 scheduled=0 claimed=0 blocked=0 failed=0 processes=0 finished=2", status
  ensure
    Process.kill("KILL", pid) rescue nil if pid
    Process.wait(pid) rescue nil if pid
  end

  # A worker killed mid-job is pruned once its heartbeat is stale: its job fails.
  def test_dead_workers_are_pruned
    get "/models/seed"
    get "/models/shout?slow=1&seconds=5"
    log = File.join(Dir.tmpdir, "spinrail-kill-#{Process.pid}.log")
    pid = worker(log)
    wait_for(log, "Performed ShoutJob")
    Process.kill("KILL", pid)
    Process.wait(pid)
    assert_equal "ready=0 scheduled=0 claimed=1 blocked=0 failed=0 processes=1 finished=1", status
    sleep 1.1
    log = File.join(Dir.tmpdir, "spinrail-prune-#{Process.pid}.log")
    pid = worker(log, "SPINRAIL_JOBS_ALIVE_THRESHOLD" => "1")
    wait_for(log, "working jobs")
    sleep 0.3
    assert_equal "ready=0 scheduled=0 claimed=0 blocked=0 failed=1 processes=1 finished=1", status
  ensure
    if pid
      Process.kill("KILL", pid) rescue nil
      Process.wait(pid) rescue nil
    end
  end

  # The worker's hostname lands in its process row: HOSTNAME if set, else
  # /proc/sys/kernel/hostname or /etc/hostname (spinel has no Socket).
  def test_worker_reports_its_hostname
    get "/models/seed"
    log = File.join(Dir.tmpdir, "spinrail-hostname-#{Process.pid}.log")
    pid = worker(log, "HOSTNAME" => "box-a")
    wait_for(log, "working jobs on * at box-a")
  ensure
    if pid
      Process.kill("KILL", pid) rescue nil
      Process.wait(pid) rescue nil
    end
  end
end

class QueueCommandsTest < Spinrail::IntegrationTest
  include WorkerHelpers

  server_env "SPINRAIL_JOBS_INLINE" => "0"

  def test_pause_resume_retry_and_discard
    get "/models/seed"
    get "/models/shout?broken=1"
    assert_equal ["paused default"], jobs("pause default")
    assert_equal ["ready=2 scheduled=0 claimed=0 blocked=0 failed=0 processes=0 finished=0", "paused: default"], jobs("status")
    log = File.join(Dir.tmpdir, "spinrail-pause-#{Process.pid}.log")
    pid = worker(log)
    wait_for(log, "working jobs")
    sleep 0.5
    assert_equal "ready=2 scheduled=0 claimed=0 blocked=0 failed=0 processes=1 finished=0", status
    jobs("resume default")
    wait_for(log, "Failed BrokenJob")
    sleep 0.2
    assert_equal "ready=0 scheduled=0 claimed=0 blocked=0 failed=1 processes=1 finished=1", status
    assert_match(/\A\d+ BrokenJob default \["x"\] \S+ \S+  ArgumentError: broken x\z/, jobs("failed").last)
    jobs("retry all")
    50.times do
      break if File.read(log).scan("Failed BrokenJob #2").size == 2
      sleep 0.1
    end
    sleep 0.2
    assert_equal "ready=0 scheduled=0 claimed=0 blocked=0 failed=1 processes=1 finished=1", status
    assert_equal "ready=0 scheduled=0 claimed=0 blocked=0 failed=0 processes=1 finished=1", jobs("discard 2").last
    assert_equal "ready=0 scheduled=0 claimed=0 blocked=0 failed=0 processes=1 finished=0", jobs("clear").last
  ensure
    if pid
      Process.kill("KILL", pid) rescue nil
      Process.wait(pid) rescue nil
    end
  end
end

class RecurringJobsTest < Spinrail::IntegrationTest
  include WorkerHelpers

  server_env "SPINRAIL_JOBS_INLINE" => "0"

  # Two workers schedule the same tasks; each run is enqueued once.
  def test_recurring_tasks_run_once_per_slot
    get "/models/seed"
    logs = [1, 2].map { |n| File.join(Dir.tmpdir, "spinrail-recurring-#{n}-#{Process.pid}.log") }
    pids = logs.map { |log| worker(log, "SPINRAIL_ENV" => "recurring") }
    logs.each { |log| wait_for(log, "working jobs") }
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    sleep 4.5
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    get "/models/authors"
    names = response.body.split(",")
    ticks = names.count("tick")
    assert_operator ticks, :>=, 3, logs.map { |l| File.read(l) }.join
    assert_operator ticks, :<=, elapsed.ceil + 1
    assert_operator names.count("swept"), :>=, 1
    assert_operator names.count("swept"), :<=, 3
    enqueued = logs.sum { |l| File.read(l).scan("Enqueued recurring task tick").size }
    assert_operator enqueued - ticks, :<=, 2
  ensure
    (pids || []).each do |pid|
      Process.kill("KILL", pid) rescue nil
      Process.wait(pid) rescue nil
    end
  end
end

class ConcurrencyTest < Spinrail::IntegrationTest
  include WorkerHelpers

  server_env "SPINRAIL_JOBS_INLINE" => "0"

  def test_limits_concurrency
    get "/models/serial"
    # a#1, b and the first OnceJob are ready; two a's wait; the second OnceJob is dropped.
    assert_equal "ready=3 scheduled=0 claimed=0 blocked=2 failed=0 processes=0 finished=1", status
    log = File.join(Dir.tmpdir, "spinrail-serial-#{Process.pid}.log")
    pid = worker(log)
    50.times do
      break if File.read(log).scan("Performed SerialJob").size == 4
      sleep 0.1
    end
    sleep 0.2
    assert_equal "ready=0 scheduled=0 claimed=0 blocked=0 failed=0 processes=1 finished=6", status
    assert_equal %w[1 2 3 4], File.read(log).scan(/Performed SerialJob #(\d+)/).flatten
  ensure
    if pid
      Process.kill("KILL", pid) rescue nil
      Process.wait(pid) rescue nil
    end
  end

  # Failing gave the slot back: a retried job waits for it again.
  def test_retried_jobs_take_a_slot
    get "/models/serial?groups=bad"
    log = File.join(Dir.tmpdir, "spinrail-serial-retry-#{Process.pid}.log")
    pid = worker(log)
    wait_for(log, "Failed SerialJob")
    Process.kill("KILL", pid)
    Process.wait(pid)
    pid = nil
    get "/models/serial?groups=bad"
    assert_equal "ready=1 scheduled=0 claimed=0 blocked=0 failed=1 processes=1 finished=0", status
    assert_equal "ready=1 scheduled=0 claimed=0 blocked=1 failed=0 processes=1 finished=0", jobs("retry all").last
  ensure
    if pid
      Process.kill("KILL", pid) rescue nil
      Process.wait(pid) rescue nil
    end
  end

  # A pruned worker's job fails and lets the next one with its key in.
  def test_pruning_frees_the_slot
    get "/models/serial?groups=slow,slow"
    assert_equal "ready=1 scheduled=0 claimed=0 blocked=1 failed=0 processes=0 finished=0", status
    log = File.join(Dir.tmpdir, "spinrail-serial-kill-#{Process.pid}.log")
    pid = worker(log)
    50.times do
      break if status.include?("claimed=1")
      sleep 0.1
    end
    Process.kill("KILL", pid)
    Process.wait(pid)
    sleep 1.1
    log = File.join(Dir.tmpdir, "spinrail-serial-prune-#{Process.pid}.log")
    pid = worker(log, "SPINRAIL_JOBS_ALIVE_THRESHOLD" => "1")
    wait_for(log, "working jobs")
    sleep 0.3
    assert_equal "ready=0 scheduled=0 claimed=1 blocked=0 failed=1 processes=1 finished=0", status
  ensure
    if pid
      Process.kill("KILL", pid) rescue nil
      Process.wait(pid) rescue nil
    end
  end
end

class ThreadedJobsTest < Spinrail::IntegrationTest
  server_env "SPINRAIL_JOBS_INLINE" => "0"

  # Eight half-second jobs on four threads: serially they'd take 4s.
  def test_jobs_run_concurrently_on_threads
    skip "threaded jobs need Tep::SQLite" if ENV.fetch("SPINRAIL_DATABASE", "sqlite") == "postgres"
    get "/models/seed"
    get "/models/shout?slow=8"
    log = File.join(Dir.tmpdir, "spinrail-threads-#{Process.pid}.log")
    worker = Process.spawn({ "DATABASE_PATH" => database_path, "SPINRAIL_ENV" => "test", "SPINRAIL_JOBS_INLINE" => "0" },
                           File.expand_path("bin/spinrail"), "jobs", "-c", "4", out: log, err: log)
    1200.times do
      break if File.read(log).include?("working jobs on 4 threads")
      sleep 0.1
    end
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    60.times do
      break if File.read(log).scan("Performed SlowJob").size == 8
      sleep 0.1
    end
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
    assert_equal 8, File.read(log).scan("Performed SlowJob").size, File.read(log)
    assert_operator elapsed, :<, 3.0
    get "/models/authors"
    assert_equal "Ana!,Bea", response.body
  ensure
    Process.kill("KILL", worker) if worker
    Process.wait(worker) if worker
  end
end
