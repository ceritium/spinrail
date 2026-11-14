require "json"

class RuntimeTest < Rieles::IntegrationTest
  def test_request_id_header
    get "/session"
    assert_match(/\A[\w-]{16,}\z/, response["X-Request-Id"])
    get "/session", headers: { "X-Request-Id" => "abc-123" }
    assert_equal "abc-123", response["X-Request-Id"]
  end

  def test_public_files
    get "/hello.txt"
    assert_response :success
    assert_equal "static hello\n", response.body
  end
end

class LogFileTest < Rieles::IntegrationTest
  def setup
    self.class.server_env("RIELES_LOG_FILE" => File.join(Dir.tmpdir, "rieles-log-#{Process.pid}-#{name}.log"),
                          "RIELES_LOG_FORMAT" => "json", "RIELES_LOG_LEVEL" => "info")
    super
  end

  def test_json_lines_go_to_the_file
    get "/session", headers: { "X-Request-Id" => "req-1" }
    sleep 0.05
    line = File.read(self.class.server_env["RIELES_LOG_FILE"]).lines.last
    entry = JSON.parse(line)
    assert_equal "req-1", entry["request_id"]
    assert_equal "SessionsController#show", entry["action"]
    assert_equal 200, entry["status"]
    assert_equal "127.0.0.1", entry["ip"]
  end
end

class ProductionTest < Rieles::IntegrationTest
  server_env "RIELES_ENV" => "production", "SECRET_KEY_BASE" => "x" * 64, "RIELES_LOG_FORMAT" => "logfmt"

  def test_errors_hide_details
    get "/models/bang"
    assert_response 422
    get "/widgets/abc"
    assert_response :not_found
  end
end
