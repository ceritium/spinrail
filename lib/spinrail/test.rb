require "minitest/autorun"
require "json"
require "net/http"
require "socket"
require "stringio"
require "tmpdir"
require "uri"
require_relative "../spinrail"
require_relative "fixtures"
require_relative "test_html"

module Spinrail
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

    # Extra environment for the server, e.g. server_env "SPINRAIL_LOG_LEVEL" => "info".
    def self.server_env(vars = nil)
      @server_env = (@server_env || {}).merge(vars) if vars
      (superclass.respond_to?(:server_env) ? superclass.server_env : {}).merge(@server_env || {})
    end

    def setup
      @db_dir = Dir.mktmpdir("spinrail-test")
      @port = free_port
      log = File.open(File.join(ENV.fetch("SPINRAIL_APP"), "log/test.log"), "a")
      log.puts "", "== #{self.class.name}##{name}"
      log.flush
      env = { "DATABASE_PATH" => database_path, "SPINRAIL_LOG_FORMAT" => "dev",
              "SPINRAIL_ENV" => "test", "SPINRAIL_FORGERY_PROTECTION" => self.class.forgery_protection? ? "1" : "0" }
      FileUtils.mkdir_p(mail_dir)
      env["SPINRAIL_MAIL_DELIVERY"] = "file"
      env["SPINRAIL_MAIL_DIR"] = mail_dir
      if postgres?
        @pg_database = "spinrail_test_#{Process.pid}_#{object_id}"
        system("createdb", @pg_database, exception: true)
        env["DATABASE_URL"] = "postgres:///#{@pg_database}"
      end
      env["ACTIVE_STORAGE_ROOT"] = storage_root
      env.merge!(self.class.server_env)
      fixtures_sql = Fixtures.load(ENV.fetch("SPINRAIL_APP"), self.class.fixture_tables)
      unless fixtures_sql.empty?
        File.write(File.join(@db_dir, "fixtures.sql"), fixtures_sql)
        env["SPINRAIL_BOOT_SQL"] = File.join(@db_dir, "fixtures.sql")
      end
      @pid = Process.spawn(env, ENV.fetch("SPINRAIL_BINARY"), "-p", @port.to_s,
                           chdir: ENV.fetch("SPINRAIL_APP"), out: log, err: log)
      log.close
      wait_for_server
      @response = nil
      @cookies = {}
    end

    def cookies = @cookies
    def database_path = @pg_database ? "postgres:///#{@pg_database}" : File.join(@db_dir, "test.sqlite3")
    def mail_dir = File.join(@db_dir, "mails")
    def storage_root = File.join(@db_dir, "storage")

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
      system("dropdb", "--if-exists", @pg_database) if @pg_database
      FileUtils.rm_rf(@db_dir)
    end

    # SPINRAIL_DATABASE=postgres: each test gets a fresh database on the local server.
    def postgres? = ENV.fetch("SPINRAIL_DATABASE", "sqlite") == "postgres"

    Upload = Struct.new(:path, :content_type)

    # A file to send as a multipart part; relative paths are under
    # test/fixtures/files, as in Rails.
    def fixture_file_upload(path, content_type = "application/octet-stream")
      full = File.absolute_path?(path) ? path : File.join(Dir.pwd, "test/fixtures/files", path)
      Upload.new(full, content_type)
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
      range = nil
      # As in Rails, an Integer, Range or boolean in place of the text is the count.
      case text
      when Integer then count, text = text, nil
      when Range then range, text = text, nil
      when false then count, text = 0, nil
      when true then text = nil
      end
      nodes = TestHTML.select(TestHTML.parse(response.body), selector)
      nodes = nodes.select { |n| text.is_a?(Regexp) ? n.text.match?(text) : n.text.strip == text.to_s } if text
      if range
        assert_includes range, nodes.size, "Expected #{range} matches for #{selector.inspect}"
      elsif count
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
      table = Fixtures.rows(ENV.fetch("SPINRAIL_APP"))[name.to_s]
      return super unless table && args.size == 1
      table.fetch(args.first.to_s) { raise ArgumentError, "no #{name} fixture #{args.first.inspect}" }
    end

    def respond_to_missing?(name, include_private = false)
      Fixtures.rows(ENV.fetch("SPINRAIL_APP")).key?(name.to_s) || super
    end

    def assert_body_includes(text)
      assert_includes response.body, text
    end

    def refute_body_includes(text)
      refute_includes response.body, text
    end

    private

    # { post: { title: "x" } } -> [["post[title]", "x"]], as Rails tests send it.
    def flatten_params(params, prefix = nil)
      params.flat_map do |k, v|
        key = prefix ? "#{prefix}[#{k}]" : k.to_s
        case v
        when Hash then flatten_params(v, key)
        when Array then v.map { |e| ["#{key}[]", e.is_a?(Upload) ? e : e.to_s] }
        else [[key, v.is_a?(Upload) ? v : v.to_s]]
        end
      end
    end

    def local_path(location)
      uri = URI(location)
      uri.host ? uri.request_uri : location
    end

    def request(klass, path, params, headers, json = nil)
      req = klass.new(path, headers)
      fields = params && flatten_params(params)
      if json
        req.body = JSON.generate(json)
        req["Content-Type"] = "application/json"
      elsif fields&.any? { |_, v| v.is_a?(Upload) }
        req.set_form(fields.map do |k, v|
          next [k, v] unless v.is_a?(Upload)
          [k, StringIO.new(File.binread(v.path)), { filename: File.basename(v.path), content_type: v.content_type }]
        end, "multipart/form-data")
      elsif fields
        req.set_form_data(fields)
      end
      req["Cookie"] = @cookies.map { |k, v| "#{k}=#{v}" }.join("; ") unless @cookies.empty?
      @response = Net::HTTP.start("127.0.0.1", @port, read_timeout: 3) { |http| http.request(req) }
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

    # Generous: macOS scans a freshly built binary on its first launch.
    def wait_for_server
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        begin
          TCPSocket.new("127.0.0.1", @port).close
          return
        rescue Errno::ECONNREFUSED
          flunk "server exited, see log/test.log" if wait_exit(0)
          sleep 0.02
        end
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
