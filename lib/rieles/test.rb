require "minitest/autorun"
require "json"
require "net/http"
require "socket"
require "tmpdir"
require "uri"
require_relative "../rieles"
require_relative "fixtures"
require_relative "test_html"

module Rieles
  # Request tests run in CRuby against the compiled binary over HTTP. Each
  # test gets its own server and an empty database, so tests don't leak.
  class IntegrationTest < Minitest::Test
    STATUS_GROUPS = { success: 200..299, redirect: 300..399, missing: 404..404, error: 500..599 }.freeze

    attr_reader :response, :port

    # Rails turns CSRF checks off in tests; a test class can turn them on.
    def self.forgery_protection! = @forgery_protection = true
    def self.forgery_protection? = @forgery_protection == true

    # fixtures :all or fixtures :posts, :authors (test/fixtures/<table>.yml).
    def self.fixtures(*tables) = @fixture_tables = tables.map(&:to_s)

    def self.fixture_tables
      @fixture_tables || (superclass.respond_to?(:fixture_tables) ? superclass.fixture_tables : [])
    end

    # Extra environment for the server, e.g. server_env "RIELES_LOG_LEVEL" => "info".
    def self.server_env(vars = nil)
      @server_env = (@server_env || {}).merge(vars) if vars
      (superclass.respond_to?(:server_env) ? superclass.server_env : {}).merge(@server_env || {})
    end

    def setup
      @db_dir = Dir.mktmpdir("rieles-test")
      @port = free_port
      log = File.open(File.join(ENV.fetch("RIELES_APP"), "log/test.log"), "a")
      log.puts "", "== #{self.class.name}##{name}"
      log.flush
      env = { "DATABASE_PATH" => database_path, "RIELES_LOG_FORMAT" => "dev",
              "RIELES_ENV" => "test", "RIELES_FORGERY_PROTECTION" => self.class.forgery_protection? ? "1" : "0" }
      FileUtils.mkdir_p(mail_dir)
      env["RIELES_MAIL_DELIVERY"] = "file"
      env["RIELES_MAIL_DIR"] = mail_dir
      env.merge!(self.class.server_env)
      fixtures_sql = Fixtures.load(ENV.fetch("RIELES_APP"), self.class.fixture_tables)
      unless fixtures_sql.empty?
        File.write(File.join(@db_dir, "fixtures.sql"), fixtures_sql)
        env["RIELES_BOOT_SQL"] = File.join(@db_dir, "fixtures.sql")
      end
      @pid = Process.spawn(env, ENV.fetch("RIELES_BINARY"), "-p", @port.to_s,
                           chdir: ENV.fetch("RIELES_APP"), out: log, err: log)
      log.close
      wait_for_server
      @response = nil
      @cookies = {}
    end

    def cookies = @cookies
    def database_path = File.join(@db_dir, "test.sqlite3")
    def mail_dir = File.join(@db_dir, "mails")

    Delivery = Struct.new(:to, :from, :subject, :body, :html)

    # Mails the server delivered during this test, oldest first.
    def deliveries
      Dir[File.join(mail_dir, "*.eml")].sort.map do |file|
        head, body = File.read(file).split("\n\n", 2)
        headers = head.lines.to_h { |l| l.chomp.split(": ", 2) }
        text, html = body.to_s.split("\n--html--\n", 2)
        Delivery.new(headers["To"], headers["From"], headers["Subject"], text, html)
      end
    end

    def teardown
      stop_server if @pid
      FileUtils.rm_rf(@db_dir)
    end

    def get(path, headers: {}) = request(Net::HTTP::Get, path, nil, headers)
    def post(path, params: {}, headers: {}, json: nil) = request(Net::HTTP::Post, path, params, headers, json)
    def put(path, params: {}, headers: {}, json: nil) = request(Net::HTTP::Put, path, params, headers, json)
    def patch(path, params: {}, headers: {}, json: nil) = request(Net::HTTP::Patch, path, params, headers, json)
    def delete(path, headers: {}) = request(Net::HTTP::Delete, path, nil, headers)

    def follow_redirect!
      location = response["Location"] or flunk "expected a redirect, got #{response.code}"
      get(local_path(location))
    end

    def assert_response(expected, message = nil)
      status = response.code.to_i
      ok = case expected
           when Integer then status == expected
           when *STATUS_GROUPS.keys then STATUS_GROUPS[expected].cover?(status)
           else status == Lowering::STATUS.fetch(expected) { raise ArgumentError, "unknown status :#{expected}" }
           end
      assert ok, message || "Expected response #{expected.inspect}, got #{status}\n#{response.body}"
    end

    def assert_redirected_to(path)
      assert_response :redirect
      assert_equal path, local_path(response["Location"])
    end

    # assert_select "ul li.item", "First", count: 2 (text is a String or Regexp)
    def assert_select(selector, text = nil, count: nil, minimum: nil)
      nodes = TestHTML.select(TestHTML.parse(response.body), selector)
      nodes = nodes.select { |n| text.is_a?(Regexp) ? n.text.match?(text) : n.text.strip == text.to_s } if text
      if count
        assert_equal count, nodes.size, "Expected #{count} matches for #{selector.inspect}#{text ? " with #{text.inspect}" : ''}"
      elsif minimum
        assert_operator nodes.size, :>=, minimum, "Expected at least #{minimum} matches for #{selector.inspect}"
      else
        refute_empty nodes, "Expected #{selector.inspect}#{text ? " with #{text.inspect}" : ''} in:\n#{response.body}"
      end
      nodes
    end

    # posts(:first) -> the fixture row, with its id.
    def method_missing(name, *args)
      table = Fixtures.rows(ENV.fetch("RIELES_APP"))[name.to_s]
      return super unless table && args.size == 1
      table.fetch(args.first.to_s) { raise ArgumentError, "no #{name} fixture #{args.first.inspect}" }
    end

    def respond_to_missing?(name, include_private = false)
      Fixtures.rows(ENV.fetch("RIELES_APP")).key?(name.to_s) || super
    end

    def assert_body_includes(text)
      assert_includes response.body, text
    end

    def refute_body_includes(text)
      refute_includes response.body, text
    end

    private

    def local_path(location)
      uri = URI(location)
      uri.host ? uri.request_uri : location
    end

    def request(klass, path, params, headers, json = nil)
      req = klass.new(path, headers)
      if json
        req.body = JSON.generate(json)
        req["Content-Type"] = "application/json"
      elsif params
        req.set_form_data(params.transform_keys(&:to_s))
      end
      req["Cookie"] = @cookies.map { |k, v| "#{k}=#{v}" }.join("; ") unless @cookies.empty?
      @response = Net::HTTP.start("127.0.0.1", @port, read_timeout: 5) { |http| http.request(req) }
      @response.get_fields("set-cookie")&.each do |line|
        name, value = line.split(";", 2).first.split("=", 2)
        @cookies[name] = value
      end
      @response.body&.force_encoding("UTF-8")
      @response
    end

    def stop_server
      Process.kill("INT", @pid)
      Process.kill("KILL", @pid) unless wait_exit(2)
    rescue Errno::ESRCH
      nil
    end

    def free_port
      server = TCPServer.new("127.0.0.1", 0)
      server.addr[1]
    ensure
      server&.close
    end

    def wait_for_server
      100.times do
        TCPSocket.new("127.0.0.1", @port).close
        return
      rescue Errno::ECONNREFUSED
        flunk "server exited, see log/test.log" if wait_exit(0)
        sleep 0.02
      end
      flunk "server didn't start on port #{@port}"
    end

    def wait_exit(seconds)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      loop do
        return true if Process.wait(@pid, Process::WNOHANG)
        return false if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.01
      end
    rescue Errno::ECHILD
      true
    end
  end
end
