# Compiled into every app by spinel. Everything app-specific (models,
# path helpers, views) is generated around these classes at build time.

# Rails' names; tep's request.ip is the peer address.
module Tep
  class Request
    def remote_ip = @remote_host
    def user_agent = @req_headers["user-agent"]
    def protocol = ssl? ? "https://" : "http://"
    def raw_post = raw_body
  end

  class UploadedFile
    def original_filename = filename
    def content_type = type
  end
end

# `render json:` calls to_json on whatever it gets; models and relations
# generate theirs.
class String
  def to_json = Tep::Json.quote(self)
  def to_param = self
  def cache_key = self
  def to_stream_name = self
  # What a view prints for it: rich text renders sanitized, strings escape.
  def to_html = Tep.h(self)
  # Helpers that end in html_safe are emitted raw; the build decides.
  def html_safe = self
  def first(n = 1) = self[0, n]
  def last(n = 1) = n >= length ? self : self[length - n, n]
  def blank? = strip.empty?
  def present? = !blank?
  def presence = blank? ? nil : self
end

class Integer
  def to_json = to_s
  def to_param = to_s
  def seconds = self
  def minutes = self * 60
  def hours = self * 3600
  def days = self * 86400
  def weeks = self * 604800
  # Rails' lengths: a twelfth of a Gregorian year, and the year itself.
  def months = self * 2629746
  def years = self * 31556952
  alias second seconds
  alias minute minutes
  alias hour hours
  alias day days
  alias week weeks
  alias month months
  alias year years
  def ago = Time.now - self
  def from_now = Time.now + self
end

class Float
  def to_json = to_s
end

class TrueClass
  def to_json = "true"
end

class FalseClass
  def to_json = "false"
end

class Time
  # The process runs in config.time_zone (ENV["TZ"] at boot).
  def self.current = Time.now

  def to_json = "\"" + iso8601(3) + "\""
  def before?(other) = self < other
  def after?(other) = self > other
end

class NilClass
  def to_json = "null"
  def blank? = true
  def present? = false
  def presence = nil
end

class Array
  def to_json = "[" + map { |item| item.to_json }.join(",") + "]"
end

module Spinrail
  class RecordNotFound < StandardError; end

  def self.clock
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  LOG_LEVELS = { "debug" => 0, "info" => 1, "warn" => 2, "error" => 3 }.freeze

  # Collects one request's timings; subclasses decide how it is printed.
  # A worker serves one request at a time, so a single instance is enough.
  # A logging failure is reported on stderr and never fails the request.
  class Logger
    def initialize
      default = Spinrail.env == "production" ? "info" : "debug"
      @level = LOG_LEVELS.fetch(ENV.fetch("SPINRAIL_LOG_LEVEL", default), 1)
      @file = ENV.fetch("SPINRAIL_LOG_FILE", "")
      @color = @file.empty? && $stdout.tty?
      reset
    end

    def reset
      @started = 0.0
      @db = 0.0
      @view = 0.0
      @depth = 0
      @verb = ""
      @path = ""
      @action = ""
      @request_id = ""
      @ip = ""
      @location = ""
      @error = ""
      @param_names = []
      @param_values = []
    end

    def start(verb, path, action, request_id, params, ip)
      reset
      @started = Spinrail.clock
      @verb = verb
      @path = path
      @action = action
      @request_id = request_id
      @ip = ip
      params.each do |name, value|
        @param_names << name
        @param_values << (filtered?(name) ? "[FILTERED]" : value.dup.force_encoding("UTF-8").scrub("?"))
      end
      on_start if @level <= 1
    rescue StandardError => e
      failed(e)
    end

    def sql(name, statement, t0)
      ms = since(t0)
      @db += ms
      on_sql(name, statement, ms, "") if @level == 0
    rescue StandardError => e
      failed(e)
    end

    def sql_binds(name, statement, t0, binds)
      ms = since(t0)
      @db += ms
      on_sql(name, statement, ms, binds.empty? ? "" : "  " + binds.inspect) if @level == 0
    rescue StandardError => e
      failed(e)
    end

    def render_start
      @depth += 1
      Spinrail.clock
    end

    def render_end(template, t0)
      ms = since(t0)
      @depth -= 1
      @view += ms if @depth == 0
      on_render(template, ms) if @level == 0
    rescue StandardError => e
      failed(e)
    end

    def redirect(location)
      @location = location
      on_redirect if @level <= 1
    rescue StandardError => e
      failed(e)
    end

    def error(e)
      @error = e.class.name + ": " + e.message
      on_error if @level <= 3
    rescue StandardError => failure
      failed(failure)
    end

    def finish(status)
      on_finish(status, since(@started)) if @level <= 1 || (@error.length > 0 && @level <= 3)
    rescue StandardError => e
      failed(e)
    end

    def on_start; end
    def on_sql(name, statement, elapsed, binds); end
    def on_render(template, elapsed); end
    def on_redirect; end
    def on_error; end
    def on_finish(status, elapsed); end

    def emit(line)
      Spinrail.synchronize do
        if @file.empty?
          puts line
        else
          File.open(@file, "a") { |f| f.puts(line) }
        end
      end
    end

    def failed(e)
      $stderr.puts "spinrail: logging failed: " + e.class.name + ": " + e.message
    end

    def since(t0) = (Spinrail.clock - t0) * 1000.0
    def ms(value) = format("%.1f", value)
    def time = Time.now.strftime("%Y-%m-%dT%H:%M:%S%z")

    def filtered?(name)
      key = name.downcase
      Spinrail.filter_parameters.any? { |f| key.include?(f) }
    end

    def escape(text)
      out = +""
      text.each_char do |c|
        out << if c == "\"" then "\\\""
               elsif c == "\\" then "\\\\"
               elsif c == "\n" then "\\n"
               elsif c == "\t" then "\\t"
               else c
               end
      end
      out
    end

    def paint(text, code)
      @color ? "\e[" + code + "m" + text + "\e[0m" : text
    end
  end

  # Rails-style, several lines per request.
  class DevLogger < Logger
    def on_start
      emit ""
      emit "Started " + @verb + " " + @path.inspect + (@ip.empty? ? "" : " for " + @ip) + " at " +
           Time.now.strftime("%Y-%m-%d %H:%M:%S") + " [" + @request_id + "]"
      emit "Processing by " + @action if @action.length > 0
      return if @param_names.empty?
      pairs = []
      i = 0
      while i < @param_names.length
        pairs << @param_names[i].inspect + " => " + @param_values[i].inspect
        i += 1
      end
      emit "  Parameters: {" + pairs.join(", ") + "}"
    end

    def on_sql(name, statement, elapsed, binds)
      emit "  " + paint(name + " (" + ms(elapsed) + "ms)", "1;36") + "  " + paint(statement, "1;34") + binds
    end

    def on_render(template, elapsed)
      emit "  Rendered " + template + " (" + ms(elapsed) + "ms)"
    end

    def on_redirect
      emit "Redirected to " + @location
    end

    def on_error
      emit paint("  " + @error, "1;31")
    end

    def on_finish(status, elapsed)
      line = "Completed " + status.to_s + " " + Tep.reason(status) + " in " + ms(elapsed) + "ms" \
             " (Views: " + ms(@view) + "ms | DB: " + ms(@db) + "ms)"
      emit paint(line, status >= 500 ? "1;31" : (status >= 400 ? "1;33" : "1;32"))
    end
  end

  # One line per request: key=value, quoted when needed.
  class LogfmtLogger < Logger
    def on_finish(status, elapsed)
      line = "time=" + time + " request_id=" + value(@request_id) + " method=" + @verb + " path=" + value(@path)
      line = line + " ip=" + value(@ip) unless @ip.empty?
      line = line + " action=" + value(@action) if @action.length > 0
      line = line + " status=" + status.to_s + " duration_ms=" + ms(elapsed) +
             " view_ms=" + ms(@view) + " db_ms=" + ms(@db)
      line = line + " location=" + value(@location) if @location.length > 0
      line = line + " error=" + value(@error) if @error.length > 0
      emit line
    end

    def value(text)
      return text unless text.empty? || text.include?(" ") || text.include?("=") || text.include?("\"")
      "\"" + escape(text) + "\""
    end
  end

  # One JSON object per request.
  class JsonLogger < Logger
    def on_finish(status, elapsed)
      fields = ["\"time\":" + str(time), "\"request_id\":" + str(@request_id),
                "\"method\":" + str(@verb), "\"path\":" + str(@path)]
      fields << "\"ip\":" + str(@ip) unless @ip.empty?
      fields << "\"action\":" + str(@action) if @action.length > 0
      fields << "\"status\":" + status.to_s
      fields << "\"duration_ms\":" + ms(elapsed)
      fields << "\"view_ms\":" + ms(@view)
      fields << "\"db_ms\":" + ms(@db)
      fields << "\"location\":" + str(@location) if @location.length > 0
      fields << "\"error\":" + str(@error) if @error.length > 0
      emit "{" + fields.join(",") + "}"
    end

    def str(text)
      "\"" + escape(text) + "\""
    end
  end

  def self.filter_parameters
    ENV.fetch("SPINRAIL_FILTER_PARAMETERS", "password,token,secret,_key,crypt,salt,certificate,otp,ssn").split(",")
  end

  def self.build_logger
    default = Spinrail.env == "production" ? "logfmt" : "dev"
    format = ENV.fetch("SPINRAIL_LOG_FORMAT", default)
    return LogfmtLogger.new if format == "logfmt"
    return JsonLogger.new if format == "json"
    DevLogger.new
  end

  LOG = build_logger

  def self.log = LOG

  # Reuses a sane incoming X-Request-Id, as Rails does behind a proxy.
  def self.request_id(req)
    incoming = req.req_headers["x-request-id"]
    if incoming && incoming.length > 0 && incoming.length <= 200 && incoming.match?(/\A[\w\-.]+\z/)
      return incoming
    end
    Crypto.sp_crypto_random_b64url(16)
  end

  def self.env = ENV.fetch("SPINRAIL_ENV", "development")

  # Off in tests unless a test asks for it, as in Rails.
  def self.forgery_protection?
    ENV.fetch("SPINRAIL_FORGERY_PROTECTION", Spinrail.env == "test" ? "0" : "1") == "1"
  end

  def self.database_path
    ENV.fetch("DATABASE_PATH", "./db/development.sqlite3")
  end

  # tep keeps only the last of repeated "ids[]" pairs; number them like JSON
  # arrays instead.
  def self.index_array_params(query, params)
    return unless query.include?("%5B%5D") || query.include?("[]")
    counts = { "" => 0 }
    query.split("&").each do |pair|
      eq = pair.index("=")
      key = SpinelKit::Url.unescape(eq.nil? ? pair : pair[0, eq])
      next unless key.end_with?("[]")
      base = key[0, key.length - 2]
      n = counts.fetch(base, 0)
      params[base + "[" + n.to_s + "]"] = eq.nil? ? "" : SpinelKit::Url.unescape(pair[eq + 1, pair.length - eq - 1])
      counts[base] = n + 1
    end
  end

  # value + "--" + an HMAC bound to the purpose; "" when it doesn't verify.
  def self.signed(value, purpose)
    value + "--" + Crypto.sp_crypto_hmac_sha256_hex(Tep.session_secret, purpose + ":" + value)
  end

  def self.verified(signed, purpose)
    cut = signed.rindex("--")
    return "" if cut.nil?
    value = signed[0, cut]
    Tep.timing_safe_eq(signed, Spinrail.signed(value, purpose)) ? value : ""
  end

  def self.storage_root
    ENV.fetch("ACTIVE_STORAGE_ROOT", Spinrail.env == "test" ? "tmp/storage" : "storage")
  end

  def self.escape_path(text) = SpinelKit::Url.escape(text)

  class RecordInvalid < StandardError; end
  class RecordNotDestroyed < StandardError; end
  class ParameterMissing < StandardError; end
  # Model.new(params.require(:post)) without permit/expect, as in Rails.
  class ForbiddenAttributesError < StandardError; end

  # A JSON request body flattened into form-style names: {"post": {"title":
  # "x"}} -> "post[title]" => "x", arrays -> "ids[0]", null -> "".
  class JsonParams
    def initialize(text, into)
      @s = text
      @i = 0
      @out = into
    end

    def parse
      skip_ws
      object("") if peek == "{"
      @out
    end

    def peek = @i < @s.length ? @s[@i] : ""

    def skip_ws
      @i += 1 while @i < @s.length && (@s[@i] == " " || @s[@i] == "\n" || @s[@i] == "\t" || @s[@i] == "\r")
    end

    def object(prefix)
      @i += 1
      skip_ws
      if peek == "}"
        @i += 1
        return
      end
      while @i < @s.length
        skip_ws
        key = string
        skip_ws
        @i += 1
        skip_ws
        value(prefix.empty? ? key : prefix + "[" + key + "]")
        skip_ws
        c = peek
        @i += 1
        break unless c == ","
      end
    end

    def array(name)
      @i += 1
      skip_ws
      if peek == "]"
        @i += 1
        return
      end
      n = 0
      while @i < @s.length
        skip_ws
        value(name + "[" + n.to_s + "]")
        n += 1
        skip_ws
        c = peek
        @i += 1
        break unless c == ","
      end
    end

    def value(name)
      c = peek
      if c == "{"
        object(name)
      elsif c == "["
        array(name)
      elsif c == "\""
        @out[name] = string
      else
        start = @i
        @i += 1 while @i < @s.length && !",}] \n\t\r".include?(@s[@i])
        literal = @s[start, @i - start]
        @out[name] = literal == "null" ? "" : literal
      end
    end

    def string
      @i += 1
      out = +""
      while @i < @s.length && @s[@i] != "\""
        c = @s[@i]
        if c == "\\"
          @i += 1
          e = @s[@i]
          if e == "n" then out << "\n"
          elsif e == "t" then out << "\t"
          elsif e == "r" then out << "\r"
          elsif e == "u"
            code = @s[@i + 1, 4].to_i(16)
            out << (code < 128 ? code.chr : "?")
            @i += 4
          else out << e
          end
        else
          out << c
        end
        @i += 1
      end
      @i += 1
      out
    end
  end

  # params.require(:entry).permit(:name): reads "entry[name]" form fields.
  class Parameters
    attr_reader :source, :prefix, :permitted, :filtered

    def initialize(source, prefix, files = Tep::Multipart.parse_files("", ""))
      @source = source
      @files = files
      @prefix = prefix
      @permitted = []
      @filtered = false
    end

    def require_key(key)
      nested = Parameters.new(@source, full(key), @files)
      raise ParameterMissing, "param is missing or the value is empty: " + key unless nested.any?
      nested
    end

    def permit_keys(keys)
      copy = Parameters.new(@source, @prefix, @files)
      copy.restrict(keys)
      copy
    end

    def restrict(keys)
      @permitted = keys
      @filtered = true
    end

    def any?
      start = @prefix + "["
      @source.each { |k, _| return true if k.start_with?(start) }
      @files.each { |k, _| return true if k.start_with?(start) }
      false
    end

    def has?(key)
      return false if @filtered && !@permitted.include?(key)
      @source.key?(full(key))
    end

    def get(key)
      return "" unless has?(key)
      @source[full(key)].dup.force_encoding("UTF-8").scrub("")
    end

    # user_params[:name]: "" when absent or not permitted.
    def [](key) = get(key.to_s)

    # An uploaded file under a permitted key; a file input left empty sends no name.
    def file?(key)
      return false if @filtered && !@permitted.include?(key)
      @files.key?(full(key)) && !@files[full(key)].filename.empty?
    end

    def file(key) = @files[full(key)]

    # params.fetch(:ids, []): "ids[0]", "ids[1]"... in order.
    def array(key)
      out = []
      return out if @filtered && !@permitted.include?(key)
      n = 0
      while @source.key?(full(key) + "[" + n.to_s + "]")
        out << @source[full(key) + "[" + n.to_s + "]"].dup.force_encoding("UTF-8").scrub("")
        n += 1
      end
      out
    end

    def full(key) = @prefix.empty? ? key : @prefix + "[" + key + "]"

    # Unfiltered access by full name, for params validation.
    def raw?(name) = @source.key?(name)
    def raw(name) = @source.key?(name) ? @source[name].dup.force_encoding("UTF-8").scrub("") : ""

    def prefixed?(name)
      start = name + "["
      @source.each { |k, _| return true if k.start_with?(start) }
      false
    end
  end
  class StatementInvalid < StandardError; end

  # One connection per process. Tep::SQLite has a single cursor, which is
  # fine because relations load every row before handing any out.
  class Database
    def initialize
      @conn = Tep::SQLite.new
      @open = false
    end

    # Waits on other workers' locks instead of failing with SQLITE_BUSY.
    def connection
      return @conn if @open
      raise StatementInvalid, "can't open " + Spinrail.database_path unless @conn.open(Spinrail.database_path)
      @conn.exec("PRAGMA busy_timeout = 5000")
      @conn.exec("PRAGMA journal_mode = WAL")
      @open = true
      @conn
    end

    # Called after boot: a connection must not cross the fork into workers.
    def close
      @conn.close if @open
      @open = false
    end
  end

  DB = Database.new

  def self.db = DB.connection

  # Microseconds, as Rails stores them, so two writes in one second differ.
  # datetime columns are TEXT in this format, in UTC, to the microsecond; now
  # is cut to it so a record compares equal to its reloaded self.
  def self.now
    t = Time.now
    Time.at(t.to_i, t.usec, :usec)
  end

  def self.format_time(time) = time.getutc.strftime("%Y-%m-%d %H:%M:%S.%6N")

  # A stored value (UTC) in the app's zone; empty is the epoch.
  def self.parse_time(text) = Spinrail.time_from(text, true)

  # A form's 2026-11-14T09:30, read in the app's zone as Rails does.
  def self.parse_local(text) = Spinrail.time_from(text, false)

  def self.time_from(text, utc)
    parts = text.split(/[- :T.]/)
    return Time.at(0) if parts.length < 3
    n = parts.map { |x| x.to_i }
    while n.length < 6
      n << 0
    end
    time = utc ? Time.utc(n[0], n[1], n[2], n[3], n[4], n[5]) : Time.new(n[0], n[1], n[2], n[3], n[4], n[5])
    usec = parts.length > 6 ? parts[6].ljust(6, "0")[0, 6].to_i : 0
    Time.at(time.to_i, usec, :usec)
  end

  # A where value as the column stores it.
  # application/x-www-form-urlencoded, as Rails' to_query writes it.
  def self.url_encode(text)
    out = +""
    text.bytes.each do |b|
      if (b >= 48 && b <= 57) || (b >= 65 && b <= 90) || (b >= 97 && b <= 122) || b == 45 || b == 46 || b == 95 || b == 126
        out << b.chr
      elsif b == 32
        out << "+"
      else
        hex = b.to_s(16).upcase
        out << "%" + (hex.length == 1 ? "0" + hex : hex)
      end
    end
    out
  end

  # x_path(..., q: "a b") -> "?q=a+b"; empty values stay, as in Rails.
  def self.query_string(keys, values)
    pairs = +""
    keys.each_with_index do |key, i|
      pairs << (i == 0 ? "?" : "&") + url_encode(key) + "=" + url_encode(values[i])
    end
    pairs
  end

  def self.no_binds
    binds = [""]
    binds.delete_at(0)
    binds
  end

  # sanitize_sql([sql, *values]): each ? becomes a quoted literal.
  def self.sanitize_sql(sql, values)
    out = +""
    i = 0
    sql.each_char do |c|
      if c == "?" && i < values.length
        out << "'" + values[i].gsub("'", "''") + "'"
        i += 1
      else
        out << c
      end
    end
    out
  end

  # connection.execute(sql) for statements that return nothing.
  def self.execute(sql)
    t0 = Spinrail.clock
    raise StatementInvalid, sql unless db.exec(sql)
    Spinrail.log.sql("SQL", sql, t0)
  end

  def self.sql_text(value) = value.is_a?(Time) ? Spinrail.format_time(value) : value.to_s

  def self.to_time(value) = value.is_a?(Time) ? value : Spinrail.parse_local(value.to_s)

  # Cache only SQL fixed at build time; tep keeps 64 cached statements.
  def self.prepare(sql, cached)
    db = Spinrail.db
    ok = cached ? db.prepare_cached(sql) : db.prepare(sql)
    raise StatementInvalid, "can't prepare: " + sql unless ok
    db
  end

  def self.write(db, name, sql, t0)
    rc = db.step
    db.finalize
    Spinrail.log.sql(name, sql, t0)
    raise StatementInvalid, "failed: " + sql if rc < 0
    true
  end

  # A savepoint, so it also nests inside a model test's transaction.
  def self.transaction
    db = Spinrail.db
    db.exec("SAVEPOINT spinrail_tx")
    begin
      result = yield
      db.exec("RELEASE spinrail_tx")
      result
    rescue StandardError => e
      db.exec("ROLLBACK TO spinrail_tx")
      db.exec("RELEASE spinrail_tx")
      raise e
    end
  end

  # Raised by model test assertions; not a StandardError, so
  # assert_raises(StandardError) can't swallow it.
  class AssertionFailed < Exception; end

  # Base of test/models/*_test.rb; assertions are lowered at build time
  # to spinrail_assert calls.
  class ModelTest
    def setup; end
    def teardown; end

    def spinrail_assert(ok, where, message)
      raise AssertionFailed, where + ": " + message unless ok
    end

    def flunk(message = "Flunked") = raise(AssertionFailed, message)
  end

  # Runs each test in a transaction that is rolled back afterwards.
  class TestRunner
    def initialize
      @runs = 0
      @failures = []
      @filter = ENV.fetch("SPINRAIL_TEST_NAME", "")
    end

    def run_case(name)
      return unless @filter.empty? || name.include?(@filter)
      @runs += 1
      db = Spinrail.db
      db.exec("BEGIN")
      Spinrail.reset_current
      begin
        yield
        print "."
      rescue AssertionFailed => e
        print "F"
        @failures << "Failure: " + name + "\n  " + e.message
      rescue StandardError => e
        print "E"
        @failures << "Error: " + name + "\n  " + e.class.name + ": " + e.message
      end
      db.exec("ROLLBACK")
    end

    def finish
      puts ""
      @failures.each { |f| puts "", f }
      puts "", @runs.to_s + " model tests, " + @failures.length.to_s + " failures"
      @failures.empty? ? 0 : 1
    end
  end

  # Columns added to db/schema.rb after the table was created. Every
  # column has a default, so ADD COLUMN works on existing rows.
  def self.add_missing_columns(table, names, statements)
    db = Spinrail.db
    existing = []
    db.prepare("PRAGMA table_info(" + table + ")")
    while db.step == 1
      existing << db.col_str(1)
    end
    db.finalize
    i = 0
    while i < names.length
      unless existing.include?(names[i])
        db.exec(statements[i])
        puts "spinrail: added column " + table + "." + names[i]
      end
      i += 1
    end
  end

  # Statements separated by ";\n" (test fixtures), run once at boot.
  def self.run_sql_file(path)
    db = Spinrail.db
    File.read(path).split(";\n").each do |statement|
      db.exec(statement) unless statement.strip.empty?
    end
  end

  # The request's locale; a worker serves one request at a time.
  class LocaleState
    attr_accessor :current

    def initialize
      @current = Spinrail.default_locale
    end
  end

  def self.default_locale = ENV.fetch("SPINRAIL_DEFAULT_LOCALE", "en")

  LOCALE = LocaleState.new

  def self.locale = LOCALE.current

  def self.set_locale(locale)
    LOCALE.current = locale.empty? ? Spinrail.default_locale : locale
  end

  # First language in Accept-Language the app has translations for.
  def self.locale_from_header(header)
    return "" if header.nil?
    header.split(",").each do |part|
      code = part.split(";").first.strip.split("-").first.to_s.downcase
      return code if !code.empty? && SpinrailTranslations::LOCALES.include?(code)
    end
    ""
  end

  def self.translate(key) = SpinrailTranslations::ALL[Spinrail.locale + "." + key]

  def self.t(key)
    found = Spinrail.translate(key)
    found.nil? ? "translation missing: " + Spinrail.locale + "." + key : found
  end

  def self.t_with(key, names, values)
    text = Spinrail.t(key)
    i = 0
    while i < names.length
      text = text.gsub("%{" + names[i] + "}", values[i])
      i += 1
    end
    text
  end

  # count: picks key.zero/one/other when the locale defines them.
  def self.t_count(key, count, names, values)
    branch = count == 0 && !Spinrail.translate(key + ".zero").nil? ? ".zero" : (count == 1 ? ".one" : ".other")
    chosen = Spinrail.translate(key + branch).nil? ? key : key + branch
    Spinrail.t_with(chosen, names, values).gsub("%{count}", count.to_s)
  end

  # l(record.created_at, format: :short) with time.formats.short as a
  # strftime pattern; a String in the stored format works too.
  def self.localize(timestamp, format)
    pattern = Spinrail.translate("time.formats." + format)
    pattern = format == "short" ? "%d %b %H:%M" : (format == "long" ? "%B %d, %Y %H:%M" : "%Y-%m-%d %H:%M:%S") if pattern.nil?
    Spinrail.to_time(timestamp).strftime(pattern)
  end

  def self.message(key, default, count)
    found = Spinrail.translate("errors.messages." + key)
    (found.nil? ? default : found).gsub("%{count}", count)
  end

  def self.attribute_name(model, attribute)
    found = Spinrail.translate("activerecord.attributes." + model + "." + attribute)
    found.nil? ? Spinrail.humanize(attribute) : found
  end

  # Applies one db/migrate version unless schema_migrations has it.
  def self.migrate(version, name, statements)
    db = Spinrail.db
    db.prepare("SELECT 1 FROM schema_migrations WHERE version = ?")
    db.bind_str(1, version)
    done = db.step == 1
    db.finalize
    return if done
    db.exec("BEGIN")
    statements.each do |statement|
      next if db.exec(statement)
      db.exec("ROLLBACK")
      $stderr.puts "spinrail: migration " + version + " " + name + " failed at: " + statement
      exit(1)
    end
    db.prepare("INSERT INTO schema_migrations (version) VALUES (?)")
    db.bind_str(1, version)
    db.step
    db.finalize
    db.exec("COMMIT")
    puts "spinrail: migrated " + version + " " + name
  end

  def self.latest_migration
    db = Spinrail.db
    db.prepare("SELECT version FROM schema_migrations ORDER BY version DESC LIMIT 1")
    latest = db.step == 1 ? db.col_str(0) : ""
    db.finalize
    latest
  end

  def self.unapply(version, name, statements)
    db = Spinrail.db
    db.exec("BEGIN")
    statements.each do |statement|
      next if db.exec(statement)
      db.exec("ROLLBACK")
      $stderr.puts "spinrail: rolling back " + version + " " + name + " failed at: " + statement
      exit(1)
    end
    db.prepare("DELETE FROM schema_migrations WHERE version = ?")
    db.bind_str(1, version)
    db.step
    db.finalize
    db.exec("COMMIT")
    puts "spinrail: rolled back " + version + " " + name
  end

  def self.irreversible(version, name)
    $stderr.puts "spinrail: " + version + " " + name + " can't be rolled back; define up and down"
    exit(1)
  end

  def self.say(line)
    Spinrail.synchronize do
      puts line
      $stdout.flush
    end
  end

  # A no-op unless the binary runs jobs on threads (runtime/threads.rb).
  def self.synchronize
    yield
  end

  # Rails.cache: in memory per process (like MemoryStore), or a SQLite
  # table every worker shares with SPINRAIL_CACHE_STORE=sqlite. expires_in 0
  # means no expiry.
  class Cache
    def initialize
      @values = Tep.str_hash
      @expires = { "" => 0 }
      @shared = ENV.fetch("SPINRAIL_CACHE_STORE", "memory") == "sqlite"
      @ready = false
    end

    def table
      return if @ready
      Spinrail.db.exec("CREATE TABLE IF NOT EXISTS spinrail_cache (key TEXT PRIMARY KEY, value TEXT NOT NULL, expires_at INTEGER NOT NULL)")
      @ready = true
    end

    def read(key)
      return read_shared(key) if @shared
      value = nil
      Spinrail.synchronize do
        expires = @expires.fetch(key, 0)
        if expires > 0 && Time.now.to_i >= expires
          @values.delete(key)
          @expires.delete(key)
        else
          value = @values[key]
        end
      end
      value
    end

    def read_shared(key)
      table
      db = Spinrail.db
      db.prepare("SELECT value FROM spinrail_cache WHERE key = ? AND (expires_at = 0 OR expires_at > ?)")
      db.bind_str(1, key)
      db.bind_int(2, Time.now.to_i)
      found = db.step == 1
      value = found ? db.col_str(0) : ""
      db.finalize
      found ? value : nil
    end

    def write(key, value, expires_in)
      if @shared
        table
        db = Spinrail.db
        db.prepare("INSERT OR REPLACE INTO spinrail_cache (key, value, expires_at) VALUES (?, ?, ?)")
        db.bind_str(1, key)
        db.bind_str(2, value)
        db.bind_int(3, expires_in > 0 ? Time.now.to_i + expires_in : 0)
        db.step
        db.finalize
        return value
      end
      Spinrail.synchronize do
        @values[key] = value
        @expires[key] = expires_in > 0 ? Time.now.to_i + expires_in : 0
      end
      value
    end

    def delete(key)
      if @shared
        table
        db = Spinrail.db
        db.prepare("DELETE FROM spinrail_cache WHERE key = ?")
        db.bind_str(1, key)
        db.step
        db.finalize
      end
      Spinrail.synchronize do
        @values.delete(key)
        @expires.delete(key)
      end
    end

    def clear
      if @shared
        table
        Spinrail.db.exec("DELETE FROM spinrail_cache")
      end
      Spinrail.synchronize do
        @values = Tep.str_hash
        @expires = { "" => 0 }
      end
    end
  end

  CACHE = Cache.new

  def self.cache = CACHE

  def self.cache_fetch(key, expires_in)
    cached = CACHE.read(key)
    return cached unless cached.nil?
    CACHE.write(key, yield, expires_in)
  end

  # Authorization: Basic base64(name:password), compared in constant time.
  def self.basic_auth?(req, name, password)
    header = req.req_headers["authorization"]
    return false if header.nil? || !header.start_with?("Basic ")
    encoded = header[6, header.length - 6].strip.tr("+/", "-_").delete("=")
    Tep.timing_safe_eq(Crypto.sp_crypto_b64url_decode(encoded), name + ":" + password)
  end

  def self.humanize(attribute)
    attribute.sub(/_id\z/, "").tr("_", " ").capitalize
  end

  class Record
  end

  class Errors
    def initialize(model)
      @model = model
      @attributes = []
      @messages = []
      @full_messages = []
    end

    def add(attribute, message, full_message = "")
      name = attribute.to_s
      full = full_message
      if full.empty?
        full = name == "base" ? message : Spinrail.attribute_name(@model, name) + " " + message
      end
      @attributes << name
      @messages << message
      @full_messages << full
    end

    def clear
      @attributes.clear
      @messages.clear
      @full_messages.clear
    end

    def any?
      !@full_messages.empty?
    end

    def empty?
      @full_messages.empty?
    end

    def count
      @full_messages.length
    end

    def full_messages
      @full_messages
    end

    def [](attribute)
      key = attribute.to_s
      found = []
      i = 0
      while i < @attributes.length
        found << @messages[i] if @attributes[i] == key
        i += 1
      end
      found
    end
  end

  # What a view can ask of whatever renders it: a controller, or a mailer
  # (no request, so no flash, session or CSRF token).
  class ViewContext
    def flash = Tep.str_hash
    def flash_get(key) = Tep.str_hash[key]

    def content_for_set(key, html)
      @content_for = Tep.str_hash if @content_for.nil?
      @content_for[key] = @content_for.fetch(key, "") + html
    end

    def content_for_get(key)
      return "" if @content_for.nil?
      @content_for.fetch(key, "")
    end

    def content_for?(key) = !content_for_get(key).empty?
    def session_get(key) = Tep.str_hash[key]
    def param(name) = ""
    def form_authenticity_token = ""
    def request_base_url = "http://localhost"
    def h(value) = Tep.h(value)

    def turbo_stream_tag(action, target, html)
      return "<turbo-stream action=\"" + action + "\" target=\"" + h(target) + "\"></turbo-stream>" if action == "remove"
      "<turbo-stream action=\"" + action + "\" target=\"" + h(target) + "\"><template>" + html + "</template></turbo-stream>"
    end
  end

  class Controller < ViewContext
    def initialize(req, res)
      @req = req
      @res = res
      @performed = false
      @response_body = ""
      @flash = Tep.str_hash
      Spinrail.reset_current
      sweep_flash
    end

    # Flash set by the previous request is readable now and gone after.
    def sweep_flash
      data = @req.session.data
      keys = []
      data.each { |k, _| keys << k if k.start_with?("_flash.") }
      keys.each do |k|
        @flash[k.delete_prefix("_flash.")] = data[k]
        data.delete(k)
      end
      @req.session.dirty = true unless keys.empty?
    end

    def flash = @flash
    def flash_get(key) = @flash[key]

    def flash_set(key, value)
      @flash[key] = value
      @req.session.set("_flash." + key, value)
    end

    def flash_now_set(key, value)
      @flash[key] = value
    end

    def session_get(key) = @req.session.data[key]

    def session_set(key, value)
      @req.session.set(key, value.to_s)
    end

    def session_delete(key)
      @req.session.data.delete(key)
      @req.session.dirty = true
    end

    def cookie_get(key) = @req.cookies[key]

    def cookie_set(key, value) = cookie_write(key, value, false, false, false, "Lax")
    def cookie_set_permanent(key, value) = cookie_write(key, value, true, false, false, "Lax")
    def cookie_set_signed(key, value) = cookie_write(key, value, false, true, false, "Lax")
    def cookie_set_permanent_signed(key, value) = cookie_write(key, value, true, true, false, "Lax")

    # cookies[...] = { value:, httponly:, same_site: } lowers here directly.
    def cookie_write(key, value, permanent, signed, httponly, same_site)
      text = value.to_s
      text = text + "--" + Crypto.sp_crypto_hmac_sha256_hex(Tep.session_secret, text) if signed
      opts = Tep.str_hash
      opts["Path"] = "/"
      opts["SameSite"] = same_site
      opts["Max-Age"] = "630720000" if permanent
      opts["HttpOnly"] = "" if httponly
      @res.set_cookie(key, text, opts)
    end

    # value--hmac, verified with the session secret.
    def cookie_get_signed(key) = Spinrail.verify_signed(@req.cookies[key])

    def cookie_delete(key)
      opts = Tep.str_hash
      opts["Path"] = "/"
      opts["Max-Age"] = "0"
      @res.set_cookie(key, "", opts)
    end

    # The best Accept-Language match among config/locales, or "".
    def locale_from_accept_language = Spinrail.locale_from_header(@req.req_headers["accept-language"])

    def wants_turbo_stream?
      accept = @req.req_headers["accept"]
      !accept.nil? && accept.include?("text/vnd.turbo-stream.html")
    end

    def render_turbo_stream(html, status)
      @res.headers["Content-Type"] = "text/vnd.turbo-stream.html; charset=utf-8"
      render_html(html, status)
    end

    def render_svg(svg, status)
      @res.headers["Content-Type"] = "image/svg+xml; charset=utf-8"
      render_html(svg, status)
    end

    def wants_json?
      return Tep.param(@req, "format") == "json" unless Tep.param(@req, "format").empty?
      accept = @req.req_headers["accept"]
      !accept.nil? && accept.include?("application/json") && !accept.include?("text/html")
    end

    def reset_session
      @req.session.clear
    end

    def form_authenticity_token
      token = @req.session.data["_csrf_token"]
      return token if token && token.length > 0
      fresh = Crypto.sp_crypto_random_b64url(32)
      @req.session.set("_csrf_token", fresh)
      fresh
    end

    def verified_request?
      return true if @req.verb == "GET" || @req.verb == "HEAD"
      expected = @req.session.data["_csrf_token"]
      return false if expected.nil? || expected.empty?
      token = Tep.param(@req, "authenticity_token")
      if token.empty?
        header = @req.req_headers["x-csrf-token"]
        token = header if header
      end
      Tep.timing_safe_eq(token, expected)
    end

    def redirect_with_flash(location, status, notice, alert)
      flash_set("notice", notice) unless notice.empty?
      flash_set("alert", alert) unless alert.empty?
      redirect_to(location, status)
    end

    def performed?
      @performed
    end

    def params = Parameters.new(@req.params, "", @req.files)

    def request_base_url
      host = @req.req_headers["host"]
      host = "localhost" if host.nil?
      (Tep::APP.tls_cert.length > 0 ? "https://" : "http://") + host
    end
    def request = @req
    def response = @res

    def response_body
      @response_body
    end

    # Form params arrive as ASCII-8BIT, and a missing one as a frozen "".
    def param(name)
      Tep.param(@req, name).dup.force_encoding("UTF-8").scrub("")
    end

    def redirect_to(location, status)
      Spinrail.log.redirect(location)
      @res.set_status(status)
      @res.headers["Location"] = location
      @response_body = ""
      @performed = true
    end

    def render_html(html, status)
      @res.set_status(status)
      @response_body = html
      @performed = true
    end

    def render_json(text, status)
      @res.headers["Content-Type"] = "application/json"
      render_html(text, status)
    end

    def head(status)
      render_html("", status)
    end

    def render_plain(text, status, content_type = "text/plain")
      @res.headers["Content-Type"] = content_type + "; charset=utf-8"
      render_html(text, status)
    end

    # send_file path, type: the server streams it with sendfile(2).
    def send_file(path, content_type, disposition, filename)
      return head(404) unless File.exist?(path)
      @res.headers["Content-Type"] = content_type
      @res.headers["Content-Disposition"] = disposition + (filename.empty? ? "" : "; filename=\"" + filename.gsub("\"", "%22") + "\"")
      @res.set_status(200)
      @res.send_file(path)
      @response_body = ""
      @performed = true
    end

    def send_data(data, content_type, disposition, filename)
      @res.headers["Content-Disposition"] = disposition + (filename.empty? ? "" : "; filename=\"" + filename.gsub("\"", "%22") + "\"")
      @res.headers["Content-Type"] = content_type
      render_html(data, 200)
    end

    def expires_in(seconds, public: false)
      @res.headers["Cache-Control"] = "max-age=#{seconds}" + (public ? ", public" : ", private")
    end

    def h(value)
      Tep.h(value)
    end
  end

  # A rendered email. deliver_later queues it already rendered, as JSON.
  class Mail
    attr_reader :to, :from, :subject, :text, :html

    def initialize(to, from, subject, text, html)
      @to = to
      @from = from
      @subject = subject
      @text = text
      @html = html
    end

    def deliver_now
      Spinrail.deliver(self)
      self
    end

    def deliver_later
      Spinrail::Jobs.enqueue("Spinrail::Mail", [to_json], "", -1, "")
      self
    end

    def to_json
      fields = ["\"from\":" + @from.to_json, "\"to\":" + @to.to_json, "\"subject\":" + @subject.to_json]
      fields << "\"text\":" + @text.to_json unless @text.empty?
      fields << "\"html\":" + @html.to_json unless @html.empty?
      "{" + fields.join(",") + "}"
    end

    def self.from_json(text)
      h = Spinrail::JsonParams.new(text, Tep.str_hash).parse
      Mail.new(h.fetch("to", ""), h.fetch("from", ""), h.fetch("subject", ""), h.fetch("text", ""), h.fetch("html", ""))
    end

    def to_s
      body = @text.empty? ? @html : @text
      out = "To: " + @to + "\nFrom: " + @from + "\nSubject: " + @subject + "\n\n" + body
      out = out + "\n--html--\n" + @html unless @text.empty? || @html.empty?
      out
    end
  end

  # Mailers render templates like controllers, without a request.
  class Mailer < ViewContext
    def default_from = "from@example.com"

    def spinrail_mail(to, from, subject, text, html)
      Mail.new(to, from.empty? ? default_from : from, subject, text, html)
    end
  end

  class DeliveryFailed < StandardError; end

  # SPINRAIL_MAIL_DELIVERY: log (default) prints it; file writes it into
  # SPINRAIL_MAIL_DIR (default tmp/mails), which tests read back; http POSTs
  # {from, to, subject, text, html} as JSON to SPINRAIL_MAIL_URL with
  # SPINRAIL_MAIL_TOKEN as a bearer token (the shape Resend's API takes).
  def self.deliver(mail)
    method = ENV.fetch("SPINRAIL_MAIL_DELIVERY", "log")
    if method == "http"
      headers = Tep.str_hash
      headers["Content-Type"] = "application/json"
      token = ENV.fetch("SPINRAIL_MAIL_TOKEN", "")
      headers["Authorization"] = "Bearer " + token unless token.empty?
      res = Tep::Http.send_req("POST", ENV.fetch("SPINRAIL_MAIL_URL", ""), mail.to_json, headers)
      raise DeliveryFailed, "mail API answered " + res.status.to_s + ": " + res.body if res.status < 200 || res.status >= 300
    elsif method == "file"
      path = ENV.fetch("SPINRAIL_MAIL_DIR", "tmp/mails") + "/" + Time.now.strftime("%Y%m%d%H%M%S%6N") + ".eml"
      File.open(path, "w") { |f| f.write(mail.to_s) }
    else
      puts "", "Delivered mail to " + mail.to, mail.to_s, ""
      $stdout.flush
    end
  end

  # Templates are methods on ApplicationView; they see only what they are
  # passed, never controller state.
  class View
    def initialize(controller)
      @controller = controller
    end

    def flash = @controller.flash
    def content_for_set(key, html) = @controller.content_for_set(key, html)
    def content_for_get(key) = @controller.content_for_get(key)
    def content_for?(key) = @controller.content_for?(key)
    def flash_get(key) = @controller.flash_get(key)
    def notice = @controller.flash_get("notice")
    def alert = @controller.flash_get("alert")
    def session_get(key) = @controller.session_get(key)
    def param(name) = @controller.param(name)
    def form_authenticity_token = @controller.form_authenticity_token
    def turbo_stream_tag(action, target, html) = @controller.turbo_stream_tag(action, target, html)

    def turbo_stream_from_tag(name, channel)
      signed = Spinrail::Cable.signed(channel, name)
      "<turbo-cable-stream-source channel=\"" + h(channel) + "\" signed-stream-name=\"" + h(signed) + "\"></turbo-cable-stream-source>"
    end
    def request_base_url = @controller.request_base_url

    def form_open(action, method, attrs)
      verb = method.downcase
      html = "<form action=\"" + h(action) + "\" method=\"" + (verb == "get" ? "get" : "post") + "\"" + attrs + ">"
      unless verb == "get" || verb == "post"
        html = html + "<input type=\"hidden\" name=\"_method\" value=\"" + h(verb) + "\">"
      end
      unless verb == "get"
        html = html + "<input type=\"hidden\" name=\"authenticity_token\" value=\"" + h(form_authenticity_token) + "\">"
      end
      html
    end

    def field_name(scope, attribute) = scope.empty? ? attribute : scope + "[" + attribute + "]"
    def field_id(scope, attribute) = scope.empty? ? attribute : scope + "_" + attribute

    def form_label(scope, attribute, text, attrs)
      "<label for=\"" + field_id(scope, attribute) + "\"" + attrs + ">" + h(text) + "</label>"
    end

    def form_input(type, scope, attribute, value, attrs)
      "<input type=\"" + type + "\" name=\"" + field_name(scope, attribute) + "\" id=\"" + field_id(scope, attribute) +
        "\" value=\"" + h(value) + "\"" + attrs + ">"
    end

    def form_file(scope, attribute, attrs)
      "<input type=\"file\" name=\"" + field_name(scope, attribute) + "\" id=\"" + field_id(scope, attribute) + "\"" + attrs + ">"
    end

    # Lexxy's editor, a form-associated element: it submits its own value.
    def form_rich_textarea(scope, attribute, value, attrs)
      "<lexxy-editor name=\"" + field_name(scope, attribute) + "\" id=\"" + field_id(scope, attribute) + "\" value=\"" + h(value) + "\"" +
        (attrs.include?(" class=") ? "" : " class=\"lexxy-content\"") + attrs + "></lexxy-editor>"
    end

    def form_textarea(scope, attribute, value, attrs)
      "<textarea name=\"" + field_name(scope, attribute) + "\" id=\"" + field_id(scope, attribute) + "\"" + attrs + ">" +
        h(value) + "</textarea>"
    end

    # The hidden "0" makes an unchecked box submit false, as in Rails.
    def form_check_box(scope, attribute, checked, attrs)
      "<input type=\"hidden\" name=\"" + field_name(scope, attribute) + "\" value=\"0\">" \
        "<input type=\"checkbox\" name=\"" + field_name(scope, attribute) + "\" id=\"" + field_id(scope, attribute) +
        "\" value=\"1\"" + (checked ? " checked" : "") + attrs + ">"
    end

    def form_select(scope, attribute, value, choices, attrs)
      html = "<select name=\"" + field_name(scope, attribute) + "\" id=\"" + field_id(scope, attribute) + "\"" + attrs + ">"
      choices.each do |choice|
        html = html + "<option value=\"" + h(choice) + "\"" + (choice == value ? " selected" : "") + ">" + h(choice) + "</option>"
      end
      html + "</select>"
    end

    def form_submit(text, attrs)
      "<input type=\"submit\" name=\"commit\" value=\"" + h(text) + "\"" + attrs + ">"
    end

    def link_to(text, url, attrs)
      "<a href=\"" + h(url) + "\"" + attrs + ">" + h(text) + "</a>"
    end

    def button_to(text, url, method, attrs)
      form_open(url, method, " class=\"button_to\"") + "<button type=\"submit\"" + attrs + ">" + h(text) + "</button></form>"
    end

    # <%= paginate @posts %>: previous/next links and page numbers as ?page=N.
    def pagination_links(current, total)
      return "" if total <= 1
      html = "<nav class=\"pagination\">"
      html = html + "<a rel=\"prev\" href=\"?page=" + (current - 1).to_s + "\">&lsaquo; Prev</a> " if current > 1
      page = 1
      while page <= total
        html += (page == current ? "<span class=\"current\">" + page.to_s + "</span> " : "<a href=\"?page=" + page.to_s + "\">" + page.to_s + "</a> ")
        page += 1
      end
      html = html + "<a rel=\"next\" href=\"?page=" + (current + 1).to_s + "\">Next &rsaquo;</a>" if current < total
      html + "</nav>"
    end

    # "style" -> /style.css; absolute paths and URLs are kept.
    # The digested name when app/assets has the file.
    def asset_path(source, extension)
      return source if source.start_with?("/") || source.include?("://")
      name = source.include?(".") ? source : source + extension
      SpinrailAssets::DIGESTS.fetch(name, "/" + name)
    end

    def stylesheet_link_tag(source, attrs)
      if source == "all"
        tags = +""
        SpinrailAssets::STYLESHEETS.each { |name| tags << stylesheet_link_tag(name, attrs) + "\n" unless name.empty? }
        return tags
      end
      "<link rel=\"stylesheet\" href=\"" + h(asset_path(source, ".css")) + "\"" + attrs + ">"
    end

    def javascript_include_tag(source, attrs)
      "<script src=\"" + h(asset_path(source, ".js")) + "\"" + attrs + "></script>"
    end

    def javascript_importmap_tags(entry)
      SpinrailAssets::IMPORTMAP + "\n<script type=\"module\">import \"" + h(entry) + "\"</script>"
    end

    def image_tag(source, attrs)
      "<img src=\"" + h(asset_path(source, "")) + "\"" + attrs + ">"
    end

    # Rails says image/x-icon for any file; the type follows the extension here.
    def favicon_link_tag(source, rel, type, attrs)
      if type.empty?
        type = if source.end_with?(".svg") then "image/svg+xml"
               elsif source.end_with?(".png") then "image/png"
               else "image/x-icon"
               end
      end
      "<link rel=\"" + h(rel) + "\" type=\"" + h(type) + "\" href=\"" + h(asset_path(source, "")) + "\"" + attrs + ">"
    end

    def csrf_meta_tags
      "<meta name=\"csrf-param\" content=\"authenticity_token\">\n" \
        "<meta name=\"csrf-token\" content=\"" + h(form_authenticity_token) + "\">"
    end

    def h(value)
      Tep.h(value)
    end

    def truncate(text, length: 30, omission: "...")
      return text if text.length <= length
      text[0, length - omission.length] + omission
    end

    # Escapes, then <p> per blank-line-separated block and <br> per newline.
    def simple_format(text)
      blocks = h(text).gsub("\r\n", "\n").split("\n\n")
      blocks.map { |b| "<p>" + b.strip.gsub("\n", "<br>") + "</p>" }.join("\n")
    end

    # number.format.delimiter / separator from the locale, else "," and ".".
    def number_with_delimiter(number)
      delimiter = Spinrail.translate("number.format.delimiter")
      separator = Spinrail.translate("number.format.separator")
      plain = number_with_commas(number)
      return plain if delimiter.nil? && separator.nil?
      plain.gsub(",", "\u0000").gsub(".", separator.nil? ? "." : separator).gsub("\u0000", delimiter.nil? ? "," : delimiter)
    end

    def number_with_commas(number)
      digits = number.to_s
      sign = digits.start_with?("-") ? "-" : ""
      digits = digits.delete_prefix("-")
      whole = digits.split(".").first
      rest = digits.include?(".") ? "." + digits.split(".").last : ""
      groups = []
      while whole.length > 3
        groups.unshift(whole[whole.length - 3, 3])
        whole = whole[0, whole.length - 3]
      end
      groups.unshift(whole)
      sign + groups.join(",") + rest
    end

    def field_errors_wrap(valid, html)
      valid ? html : "<div class=\"field_with_errors\">" + html + "</div>"
    end

    def form_select_pairs(scope, attribute, value, values, labels, attrs)
      html = "<select name=\"" + field_name(scope, attribute) + "\" id=\"" + field_id(scope, attribute) + "\"" + attrs + ">"
      i = 0
      while i < values.length
        html = html + "<option value=\"" + h(values[i]) + "\"" + (values[i] == value ? " selected" : "") + ">" + h(labels[i]) + "</option>"
        i += 1
      end
      html + "</select>"
    end

    def number_to_currency(number, unit: "$", precision: 2)
      amount = format("%." + precision.to_s + "f", number.to_f.abs)
      unit = Spinrail.translate("number.currency.format.unit") || unit if unit == "$"
      (number.to_f < 0 ? "-" : "") + unit + number_with_delimiter(amount)
    end

    # Timestamps are "YYYY-MM-DD HH:MM:SS[.ffffff]" local time (see Spinrail.now).
    def time_ago_in_words(timestamp)
      seconds = Time.now.to_i - Spinrail.to_time(timestamp).to_i
      minutes = seconds / 60
      return "less than a minute" if minutes < 1
      return pluralize(minutes, "minute") if minutes < 45
      return "about " + pluralize((minutes + 30) / 60, "hour") if minutes < 1440
      days = (minutes + 720) / 1440
      return pluralize(days, "day") if days < 30
      months = (days + 15) / 30
      return pluralize(months, "month") if months < 12
      "about " + pluralize((months + 6) / 12, "year")
    end

    def pluralize(count, singular)
      count.to_s + " " + (count == 1 ? singular : singular + "s")
    end
  end
end

# Turbo Streams over Action Cable's protocol (actioncable-v1-json), so the
# turbo-rails client works unchanged. Only Turbo::StreamsChannel: a
# subscription is authorized by its signed stream name, as in turbo-rails.
module Spinrail
  def self.verify_signed(raw)
    return nil if raw.nil?
    cut = raw.rindex("--")
    return nil if cut.nil?
    value = raw[0, cut]
    Tep.timing_safe_eq(raw[cut + 2, raw.length - cut - 2], Crypto.sp_crypto_hmac_sha256_hex(Tep.session_secret, value)) ? value : nil
  end

  # generates_token_for: "id.expires_at.hmac" (expires_at 0: never), the
  # HMAC covering the purpose and the record's token data too.
  def self.token_for(id, purpose, ttl, data)
    payload = id.to_s + "." + (ttl > 0 ? (Time.now.to_i + ttl).to_s : "0")
    payload + "." + Crypto.sp_crypto_hmac_sha256_hex(Tep.session_secret, purpose + "." + payload + "." + data)
  end

  # The record id of a well-formed, unexpired token; 0 otherwise.
  def self.token_record_id(token)
    parts = token.to_s.split(".")
    return 0 unless parts.length == 3 && parts[0].to_i.to_s == parts[0] && parts[1].to_i.to_s == parts[1]
    expires = parts[1].to_i
    return 0 if expires != 0 && expires < Time.now.to_i
    parts[0].to_i
  end

  def self.token_matches?(token, purpose, data)
    cut = token.rindex(".")
    payload = token[0, cut]
    Tep.timing_safe_eq(token[cut + 1, token.length - cut - 1], Crypto.sp_crypto_hmac_sha256_hex(Tep.session_secret, purpose + "." + payload + "." + data))
  end

  class CableSub
    attr_reader :fd, :identifier, :stream

    def initialize(fd, identifier, stream)
      @fd = fd
      @identifier = identifier
      @stream = stream
    end
  end

  # ActionCable::Connection::Base: built from the upgrade request.
  class CableConnection
    def initialize(req)
      @req = req
      @rejected = false
    end

    def connect = nil
    def rejected? = @rejected
    def cookie_get_signed(key) = Spinrail.verify_signed(@req.cookies[key])

    def reject_unauthorized_connection
      @rejected = true
      nil
    end
  end

  # ActionCable::Channel::Base: subscribed decides the streams or rejects.
  class CableChannel
    attr_accessor :connection
    attr_reader :streams

    def initialize(identifier)
      @identifier = identifier
      @streams = []
      @rejected = false
    end

    def subscribed = nil
    def rejected? = @rejected
    def param(key) = Tep::Json.get_str(@identifier, key)
    def verified_stream_name_from_params = Spinrail::Cable.verified(param("channel"), param("signed_stream_name"))

    def stream_from(name)
      @streams << name
      nil
    end

    def reject
      @rejected = true
      nil
    end
  end

  module Cable
    PROTOCOL = "actioncable-v1-json".freeze
    CHANNEL = "Turbo::StreamsChannel".freeze
    PING_TOPIC = "spinrail:cable:ping".freeze
    PINGER = [false]
    SUBS = [Spinrail::CableSub.new(-1, "", "")]
    SUBS.delete_at(0)

    def self.upgrade(req, res, connection)
      hs = Tep::WebSocket::Handshake.check(req)
      unless hs.valid
        res.set_status(400)
        return ""
      end
      connection.connect
      driver = Tep::WebSocket::Driver.new(0)
      driver.set_subprotocol(PROTOCOL) if hs.protocols.include?(PROTOCOL)
      on_open = Spinrail::CableOpen.new
      on_open.ws = driver
      on_open.connection = connection
      on_message = Spinrail::CableMessage.new
      on_message.ws = driver
      on_message.connection = connection
      on_close = Spinrail::CableClose.new
      on_close.ws = driver
      driver.set_on_open(on_open)
      driver.set_on_message(on_message)
      driver.set_on_close(on_close)
      res.start_websocket(hs.accept_key, driver)
      ""
    end

    # The client reconnects after 6 s without a ping.
    def self.start_pinger
      return if PINGER[0]
      PINGER[0] = true
      Tep::Scheduler.spawn_fiber(Fiber.new { Spinrail::Cable.ping_forever })
    end

    # Ends on shutdown: a live fiber keeps the worker loop running.
    def self.ping_forever
      while Sock.sphttp_shutdown_requested == 0
        Tep::Scheduler.pause(3)
        Tep::Broadcast.publish(PING_TOPIC, "{\"type\":\"ping\",\"message\":" + Time.now.to_i.to_s + "}")
      end
    end

    # Signed for one channel: a name a guarded channel hands out can't be
    # replayed through Turbo::StreamsChannel, which checks nothing else.
    def self.signed(channel, name) = name + "--" + Crypto.sp_crypto_hmac_sha256_hex(Tep.session_secret, "turbo:" + channel + ":" + name)

    def self.verified(channel, signed)
      cut = signed.rindex("--")
      return "" if cut.nil?
      name = signed[0, cut]
      Tep.timing_safe_eq(signed, Cable.signed(channel, name)) ? name : ""
    end

    def self.receive(ws, data, connection)
      return if connection.rejected?
      command = Tep::Json.get_str(data, "command")
      identifier = Tep::Json.get_str(data, "identifier")
      channel = Tep::Json.get_str(identifier, "channel")
      if command == "subscribe"
        Cable.unsubscribe(ws.fd, identifier)
        ok = channel == CHANNEL ? Cable.subscribe_turbo(identifier, ws.fd) : Cable.subscribe_channel(channel, connection, identifier, ws.fd)
        ws.text("{\"identifier\":" + Tep::Json.quote(identifier) + ",\"type\":\"" + (ok ? "confirm" : "reject") + "_subscription\"}")
      elsif command == "unsubscribe"
        Cable.unsubscribe(ws.fd, identifier)
      end
    end

    def self.subscribe_turbo(identifier, fd)
      name = Cable.verified(CHANNEL, Tep::Json.get_str(identifier, "signed_stream_name"))
      return false if name.empty?
      Cable.subscribe(fd, identifier, name)
      true
    end

    def self.subscribe(fd, identifier, stream)
      SUBS << Spinrail::CableSub.new(fd, identifier, stream)
    end

    def self.unsubscribe(fd, identifier)
      i = SUBS.length - 1
      while i >= 0
        SUBS.delete_at(i) if SUBS[i].fd == fd && SUBS[i].identifier == identifier
        i -= 1
      end
    end

    def self.drop(fd)
      i = SUBS.length - 1
      while i >= 0
        SUBS.delete_at(i) if SUBS[i].fd == fd
        i -= 1
      end
    end

    # Each subscriber gets the message under its own identifier, as the
    # client matches on it.
    def self.broadcast(stream, html)
      message = Tep::Json.quote(html)
      SUBS.each do |sub|
        next unless sub.stream == stream
        Tep::WebSocket::Driver.send_frame(sub.fd, Tep::WebSocket::OPCODE_TEXT,
                                          "{\"identifier\":" + Tep::Json.quote(sub.identifier) + ",\"message\":" + message + "}")
      end
    end

    # Partials rendered outside a request (model broadcasts).
    def self.view = Spinrail::ViewContext.new
  end

  class CableOpen < Tep::WebSocket::Handler
    attr_accessor :ws, :connection

    def handle_event(evt)
      if @connection.rejected?
        @ws.text("{\"type\":\"disconnect\",\"reason\":\"unauthorized\",\"reconnect\":false}")
        return 0
      end
      @ws.text("{\"type\":\"welcome\"}")
      Tep::Broadcast.subscribe_ws(Spinrail::Cable::PING_TOPIC, @ws.fd)
      Spinrail::Cable.start_pinger
      0
    end
  end

  class CableMessage < Tep::WebSocket::Handler
    attr_accessor :ws, :connection

    def handle_event(evt)
      Spinrail::Cable.receive(@ws, evt.data, @connection)
      0
    end
  end

  class CableClose < Tep::WebSocket::Handler
    attr_accessor :ws

    def handle_event(evt)
      Spinrail::Cable.drop(@ws.fd)
      0
    end
  end
end

# Outbound HTTP for integrations (OAuth, provider APIs, webhooks): a thin
# client over Tep::Http that follows redirects (Tep::Http doesn't), raises
# an error carrying the status, and encodes/decodes JSON. Tep caps each
# response at ~64 KB; keep provider API pages small.
module Spinrail
  class HTTPError < StandardError
    attr_reader :status, :body

    def initialize(status, body)
      @status = status
      @body = body
      super("HTTP " + status.to_s)
    end
  end

  module HTTP
    REDIRECTS = [301, 302, 303, 307, 308].freeze
    MAX_REDIRECTS = 5

    # A fresh headers hash (String keys and values), with extra merged in.
    def self.headers(extra = nil)
      h = Tep.str_hash
      unless extra.nil?
        extra.each { |k, v| h[k] = v }
      end
      h
    end

    def self.json_headers(extra = nil)
      h = headers(extra)
      h["Content-Type"] = "application/json"
      h
    end

    def self.bearer(token)
      h = Tep.str_hash
      h["Authorization"] = "Bearer " + token
      h
    end

    # The workhorse: verb, absolute url, body, headers, redirects left,
    # raise_on_error. Returns a Tep::Http::Response (.status, .headers,
    # .body); .status is 0 on network failure. Follows 3xx Location
    # headers up to MAX_REDIRECTS times (same verb, same body).
    def self.request(verb, url, body, headers, redirects, raise_on_error)
      res = Tep::Http.send_req(verb, url, body, headers)
      if REDIRECTS.include?(res.status) && redirects > 0
        location = res.headers["location"]
        unless location.empty?
          # A root-relative Location resolves against the current origin.
          if location[0, 1] == "/"
            parts = SpinelKit::Url.split_url(url)
            port = parts["port"]
            port = port.empty? || port == "80" || port == "443" ? "" : ":" + port
            location = parts["scheme"] + "://" + parts["host"] + port + location
          end
          return request(verb, location, body, headers, redirects - 1, raise_on_error)
        end
      end
      raise HTTPError.new(res.status, res.body) if raise_on_error && (res.status < 200 || res.status >= 300)
      res
    end

    def self.get(url, headers = nil, raise_on_error: false)
      request("GET", url, "", headers(headers), MAX_REDIRECTS, raise_on_error)
    end

    def self.post(url, body, headers = nil, raise_on_error: false)
      request("POST", url, body, headers(headers), MAX_REDIRECTS, raise_on_error)
    end

    def self.put(url, body, headers = nil, raise_on_error: false)
      request("PUT", url, body, headers(headers), MAX_REDIRECTS, raise_on_error)
    end

    def self.patch(url, body, headers = nil, raise_on_error: false)
      request("PATCH", url, body, headers(headers), MAX_REDIRECTS, raise_on_error)
    end

    def self.delete(url, headers = nil, raise_on_error: false)
      request("DELETE", url, "", headers(headers), MAX_REDIRECTS, raise_on_error)
    end

    # A request whose response body is JSON: parsed on success, HTTPError
    # otherwise (status 0, a network failure, included).
    def self.get_json(url, headers = nil)
      JSON.parse(get(url, headers, raise_on_error: true).body)
    end

    def self.post_json(url, obj, headers = nil)
      post(url, JSON.generate(obj), json_headers(headers), raise_on_error: true)
    end

    def self.put_json(url, obj, headers = nil)
      put(url, JSON.generate(obj), json_headers(headers), raise_on_error: true)
    end

    def self.patch_json(url, obj, headers = nil)
      patch(url, JSON.generate(obj), json_headers(headers), raise_on_error: true)
    end
  end
end
