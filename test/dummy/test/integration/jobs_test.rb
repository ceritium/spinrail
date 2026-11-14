class InlineJobsTest < Rieles::IntegrationTest
  def test_jobs_run_inline_in_tests
    get "/models/seed"
    get "/models/shout"
    get "/models/authors"
    assert_equal "Ana!,Bea", response.body
  end
end

class QueuedJobsTest < Rieles::IntegrationTest
  server_env "RIELES_JOBS_INLINE" => "0"

  def test_a_worker_drains_the_queue
    get "/models/seed"
    get "/models/shout?broken=1"
    get "/models/authors"
    assert_equal "Ana,Bea", response.body

    log = File.join(Dir.tmpdir, "rieles-jobs-#{Process.pid}.log")
    worker = Process.spawn({ "DATABASE_PATH" => database_path, "DATABASE_URL" => database_path, "RIELES_JOBS" => "1", "RIELES_ENV" => "test",
                             "RIELES_JOBS_INLINE" => "0" }, ENV.fetch("RIELES_BINARY"), out: log, err: log)
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

class ThreadedJobsTest < Rieles::IntegrationTest
  server_env "RIELES_JOBS_INLINE" => "0"

  # Eight half-second jobs on four threads: serially they'd take 4s.
  def test_jobs_run_concurrently_on_threads
    skip "threaded jobs need Tep::SQLite" if ENV.fetch("RIELES_DATABASE", "sqlite") == "postgres"
    get "/models/seed"
    get "/models/shout?slow=8"
    log = File.join(Dir.tmpdir, "rieles-threads-#{Process.pid}.log")
    worker = Process.spawn({ "DATABASE_PATH" => database_path, "RIELES_ENV" => "test", "RIELES_JOBS_INLINE" => "0" },
                           File.expand_path("bin/rieles"), "jobs", "-c", "4", out: log, err: log)
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
