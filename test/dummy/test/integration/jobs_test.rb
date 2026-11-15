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

class ProcessesTest < Spinrail::IntegrationTest
  server_env "SPINRAIL_JOBS_INLINE" => "0"

  def worker(log, env = {})
    Process.spawn({ "DATABASE_PATH" => database_path, "DATABASE_URL" => database_path, "SPINRAIL_JOBS" => "1", "SPINRAIL_ENV" => "test",
                    "SPINRAIL_JOBS_INLINE" => "0" }.merge(env), ENV.fetch("SPINRAIL_BINARY"), out: log, err: log)
  end

  def status
    IO.popen({ "DATABASE_PATH" => database_path, "DATABASE_URL" => database_path, "SPINRAIL_JOBS" => "status", "SPINRAIL_ENV" => "test" },
             [ENV.fetch("SPINRAIL_BINARY")], &:read).lines.last.strip
  end

  def wait_for(log, text)
    50.times do
      break if File.exist?(log) && File.read(log).include?(text)
      sleep 0.1
    end
    assert_includes File.read(log), text
  end

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
    assert_equal "ready=1 scheduled=0 claimed=0 failed=0 processes=0 finished=2", status
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
    assert_equal "ready=0 scheduled=0 claimed=1 failed=0 processes=1 finished=1", status
    sleep 1.1
    log = File.join(Dir.tmpdir, "spinrail-prune-#{Process.pid}.log")
    pid = worker(log, "SPINRAIL_JOBS_ALIVE_THRESHOLD" => "1")
    wait_for(log, "working jobs")
    sleep 0.3
    assert_equal "ready=0 scheduled=0 claimed=0 failed=1 processes=1 finished=1", status
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
