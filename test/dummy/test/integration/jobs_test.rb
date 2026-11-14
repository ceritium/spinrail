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
