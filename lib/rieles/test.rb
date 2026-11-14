require "minitest/autorun"
require "net/http"
require "socket"
require "tmpdir"
require "uri"
require "yaml"
require "zlib"
require_relative "../rieles"
require_relative "test_html"

module Rieles
  # test/fixtures/<table>.yml, as in Rails: labels get stable ids
  # (CRC32, like ActiveRecord's), `author: ana` sets author_id, and missing
  # columns take their schema default. Loaded as SQL when the server boots.
  module Fixtures
    Row = Struct.new(:attributes) do
      def id = attributes["id"]
      def [](name) = attributes[name.to_s]
      def method_missing(name, *) = attributes.key?(name.to_s) ? attributes[name.to_s] : super
      def respond_to_missing?(name, priv = false) = attributes.key?(name.to_s) || super
    end

    module_function

    def identify(label) = Zlib.crc32(label.to_s) % (2**30 - 1)

    def rows(app)
      @rows ||= {}
      @rows[app] ||= begin
        schema = Schema.new(File.join(app, "db/schema.rb"))
        Dir[File.join(app, "test/fixtures/*.yml")].sort.to_h do |file|
          table_name = File.basename(file, ".yml")
          table = schema.table(table_name) or raise "test/fixtures/#{table_name}.yml: no such table"
          data = YAML.safe_load_file(file) || {}
          [table_name, data.to_h { |label, attrs| [label.to_s, Row.new(row(table, label, attrs || {}))] }]
        end
      end
    end

    def row(table, label, attrs)
      now = Time.now.strftime("%Y-%m-%d %H:%M:%S")
      values = { "id" => identify(label) }
      attrs.each do |key, value|
        key = key.to_s
        if !table.column(key) && table.column("#{key}_id")
          values["#{key}_id"] = identify(value)
        else
          raise "fixture #{label}: #{table.name} has no column #{key}" unless table.column(key)
          values[key] = value
        end
      end
      table.columns.each do |c|
        next if values.key?(c.name)
        values[c.name] = c.timestamp? ? now : (c.default.nil? ? { integer: 0, boolean: false, float: 0.0, string: "" }.fetch(c.type) : c.default)
      end
      values
    end

    def load(app, tables)
      selected = tables.include?("all") ? rows(app) : rows(app).slice(*tables)
      missing = tables - ["all"] - selected.keys
      raise "no test/fixtures/#{missing.first}.yml" if missing.any?
      selected.map do |table, labelled|
        labelled.values.map do |r|
          names = r.attributes.keys
          "INSERT INTO #{table} (#{names.join(', ')}) VALUES (#{names.map { |n| sql(r.attributes[n]) }.join(', ')});\n"
        end.join
      end.join
    end

    def sql(value)
      case value
      when true then "1"
      when false then "0"
      when Numeric then value.to_s
      else "'#{value.to_s.gsub("'", "''")}'"
      end
    end
  end

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

    def teardown
      stop_server if @pid
      FileUtils.rm_rf(@db_dir)
    end

    def get(path, headers: {}) = request(Net::HTTP::Get, path, nil, headers)
    def post(path, params: {}, headers: {}) = request(Net::HTTP::Post, path, params, headers)
    def put(path, params: {}, headers: {}) = request(Net::HTTP::Put, path, params, headers)
    def patch(path, params: {}, headers: {}) = request(Net::HTTP::Patch, path, params, headers)
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

    def request(klass, path, params, headers)
      req = klass.new(path, headers)
      req.set_form_data(params.transform_keys(&:to_s)) if params
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
