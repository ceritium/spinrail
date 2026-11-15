class InlineJobsTest < Spinrail::IntegrationTest
  def test_jobs_run_inline_in_tests
    get "/models/seed"
    get "/models/shout"
    get "/models/authors"
    assert_equal "Ana!,Bea", response.body
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
    get "/models/shout?broken=1"
    get "/models/authors"
    assert_equal "Ana,Bea", response.body

    log = File.join(Dir.tmpdir, "spinrail-jobs-#{Process.pid}.log")
    worker = Process.spawn({ "DATABASE_PATH" => database_path, "DATABASE_URL" => database_path, "SPINRAIL_JOBS" => "1", "SPINRAIL_ENV" => "test",
                             "SPINRAIL_JOBS_INLINE" => "0" }, ENV.fetch("SPINRAIL_BINARY"), out: log, err: log)
    50.times do
      get "/models/authors"
      break if response.body == "Ana!,Bea"
      sleep 0.1
    end
    assert_equal "Ana!,Bea", response.body
    sleep 0.3
    assert_includes File.read(log), "Performed ShoutJob"
    assert_includes File.read(log), "Failed BrokenJob"
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
