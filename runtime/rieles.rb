# Compiled into every app by spinel. Everything app-specific (models,
# path helpers, views) is generated around these classes at build time.

# tep's table only knows 12 codes and answers "OK" for the rest (303 OK,
# 422 OK). An empty reason phrase is valid HTTP/1.1 (RFC 9112 §4).
module Tep
  REASONS = {
    200 => "OK",
    201 => "Created",
    202 => "Accepted",
    204 => "No Content",
    206 => "Partial Content",
    301 => "Moved Permanently",
    302 => "Found",
    303 => "See Other",
    304 => "Not Modified",
    307 => "Temporary Redirect",
    308 => "Permanent Redirect",
    400 => "Bad Request",
    401 => "Unauthorized",
    403 => "Forbidden",
    404 => "Not Found",
    405 => "Method Not Allowed",
    409 => "Conflict",
    410 => "Gone",
    413 => "Content Too Large",
    415 => "Unsupported Media Type",
    422 => "Unprocessable Content",
    429 => "Too Many Requests",
    500 => "Internal Server Error",
    501 => "Not Implemented",
    502 => "Bad Gateway",
    503 => "Service Unavailable",
    504 => "Gateway Timeout"
  }.freeze

  def self.reason(status)
    REASONS.fetch(status, "")
  end
end

# `render json:` calls to_json on whatever it gets; models and relations
# generate theirs.
class String
  def to_json = Tep::Json.quote(self)
  def to_param = self
  # Helpers that end in html_safe are emitted raw; the build decides.
  def html_safe = self
end

class Integer
  def to_json = to_s
  def to_param = to_s
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

class NilClass
  def to_json = "null"
end

class Array
  def to_json = "[" + map { |item| item.to_json }.join(",") + "]"
end

module Rieles
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
      default = Rieles.env == "production" ? "info" : "debug"
      @level = LOG_LEVELS.fetch(ENV.fetch("RIELES_LOG_LEVEL", default), 1)
      @file = ENV.fetch("RIELES_LOG_FILE", "")
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
      @location = ""
      @error = ""
      @param_names = []
      @param_values = []
    end

    def start(verb, path, action, request_id, params)
      reset
      @started = Rieles.clock
      @verb = verb
      @path = path
      @action = action
      @request_id = request_id
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
      Rieles.clock
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
      if @file.empty?
        puts line
      else
        File.open(@file, "a") { |f| f.puts(line) }
      end
    end

    def failed(e)
      $stderr.puts "rieles: logging failed: " + e.class.name + ": " + e.message
    end

    def since(t0) = (Rieles.clock - t0) * 1000.0
    def ms(value) = format("%.1f", value)
    def time = Time.now.strftime("%Y-%m-%dT%H:%M:%S%z")

    def filtered?(name)
      key = name.downcase
      Rieles.filter_parameters.any? { |f| key.include?(f) }
    end

    def escape(text)
      out = +""
      text.each_char do |c|
        if c == "\"" then out << "\\\""
        elsif c == "\\" then out << "\\\\"
        elsif c == "\n" then out << "\\n"
        elsif c == "\t" then out << "\\t"
        else out << c
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
      emit "Started " + @verb + " " + @path.inspect + " at " + Time.now.strftime("%Y-%m-%d %H:%M:%S") + " [" + @request_id + "]"
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
    ENV.fetch("RIELES_FILTER_PARAMETERS", "password,token,secret,_key,crypt,salt,certificate,otp,ssn").split(",")
  end

  def self.build_logger
    default = Rieles.env == "production" ? "logfmt" : "dev"
    format = ENV.fetch("RIELES_LOG_FORMAT", default)
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

  def self.env = ENV.fetch("RIELES_ENV", "development")

  # Off in tests unless a test asks for it, as in Rails.
  def self.forgery_protection?
    ENV.fetch("RIELES_FORGERY_PROTECTION", Rieles.env == "test" ? "0" : "1") == "1"
  end

  def self.database_path
    ENV.fetch("DATABASE_PATH", "./db/development.sqlite3")
  end

  # Bound in place of nil; the SQL wraps nullable placeholders in NULLIF.
  NULL_STR = 1.chr
  NULL_INT = -9007199254740991

  # Tep::SQLite copies text into 64 KB buffers; a full one was cut.
  def self.column_text(value)
    raise StatementInvalid, "text value longer than 64 KB was truncated by Tep::SQLite" if value.bytesize >= 65535
    value
  end

  class RecordInvalid < StandardError; end
  class ParameterMissing < StandardError; end

  # params.require(:entry).permit(:name): reads "entry[name]" form fields.
  class Parameters
    attr_reader :source, :prefix, :permitted, :filtered

    def initialize(source, prefix)
      @source = source
      @prefix = prefix
      @permitted = []
      @filtered = false
    end

    def require_key(key)
      nested = Parameters.new(@source, full(key))
      raise ParameterMissing, "param is missing or the value is empty: " + key unless nested.any?
      nested
    end

    def permit_keys(keys)
      copy = Parameters.new(@source, @prefix)
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

    def full(key) = @prefix.empty? ? key : @prefix + "[" + key + "]"
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
      raise StatementInvalid, "can't open " + Rieles.database_path unless @conn.open(Rieles.database_path)
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

  def self.now = Time.now.strftime("%Y-%m-%d %H:%M:%S")

  # Cache only SQL fixed at build time; tep keeps 64 cached statements.
  def self.prepare(sql, cached)
    db = Rieles.db
    ok = cached ? db.prepare_cached(sql) : db.prepare(sql)
    raise StatementInvalid, "can't prepare: " + sql unless ok
    db
  end

  def self.write(db, name, sql, t0)
    rc = db.step
    db.finalize
    Rieles.log.sql(name, sql, t0)
    raise StatementInvalid, "failed: " + sql if rc < 0
    true
  end

  # A savepoint, so it also nests inside a model test's transaction.
  def self.transaction
    db = Rieles.db
    db.exec("SAVEPOINT rieles_tx")
    begin
      result = yield
      db.exec("RELEASE rieles_tx")
      result
    rescue StandardError => e
      db.exec("ROLLBACK TO rieles_tx")
      db.exec("RELEASE rieles_tx")
      raise e
    end
  end

  # Raised by model test assertions; not a StandardError, so
  # assert_raises(StandardError) can't swallow it.
  class AssertionFailed < Exception; end

  # Base of test/models/*_test.rb; assertions are lowered at build time
  # to rieles_assert calls.
  class ModelTest
    def setup; end
    def teardown; end

    def rieles_assert(ok, where, message)
      raise AssertionFailed, where + ": " + message unless ok
    end

    def flunk(message = "Flunked") = raise(AssertionFailed, message)
  end

  # Runs each test in a transaction that is rolled back afterwards.
  class TestRunner
    def initialize
      @runs = 0
      @failures = []
      @filter = ENV.fetch("RIELES_TEST_NAME", "")
    end

    def run_case(name)
      return unless @filter.empty? || name.include?(@filter)
      @runs += 1
      db = Rieles.db
      db.exec("BEGIN")
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
    db = Rieles.db
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
        puts "rieles: added column " + table + "." + names[i]
      end
      i += 1
    end
  end

  # Statements separated by ";\n" (test fixtures), run once at boot.
  def self.run_sql_file(path)
    db = Rieles.db
    File.read(path).split(";\n").each do |statement|
      db.exec(statement) unless statement.strip.empty?
    end
  end

  # The request's locale; a worker serves one request at a time.
  class LocaleState
    attr_accessor :current

    def initialize
      @current = Rieles.default_locale
    end
  end

  def self.default_locale = ENV.fetch("RIELES_DEFAULT_LOCALE", "en")

  LOCALE = LocaleState.new

  def self.locale = LOCALE.current

  def self.set_locale(locale)
    LOCALE.current = locale.empty? ? Rieles.default_locale : locale
  end

  # First language in Accept-Language the app has translations for.
  def self.locale_from_header(header)
    return "" if header.nil?
    header.split(",").each do |part|
      code = part.split(";").first.strip.split("-").first.to_s.downcase
      return code if !code.empty? && RielesTranslations::LOCALES.include?(code)
    end
    ""
  end

  def self.translate(key) = RielesTranslations::ALL[Rieles.locale + "." + key]

  def self.t(key)
    found = Rieles.translate(key)
    found.nil? ? "translation missing: " + Rieles.locale + "." + key : found
  end

  def self.t_with(key, names, values)
    text = Rieles.t(key)
    i = 0
    while i < names.length
      text = text.gsub("%{" + names[i] + "}", values[i])
      i += 1
    end
    text
  end

  # count: picks key.zero/one/other when the locale defines them.
  def self.t_count(key, count, names, values)
    branch = count == 0 && !Rieles.translate(key + ".zero").nil? ? ".zero" : (count == 1 ? ".one" : ".other")
    chosen = Rieles.translate(key + branch).nil? ? key : key + branch
    Rieles.t_with(chosen, names, values).gsub("%{count}", count.to_s)
  end

  # l("2026-11-14 09:30:00", format: :short) with time.formats.short as a
  # strftime pattern; timestamps are the strings Rieles.now writes.
  def self.localize(timestamp, format)
    parts = timestamp.split(/[- :T]/).map { |x| x.to_i }
    return timestamp if parts.length < 3
    while parts.length < 6
      parts << 0
    end
    pattern = Rieles.translate("time.formats." + format)
    pattern = format == "short" ? "%d %b %H:%M" : (format == "long" ? "%B %d, %Y %H:%M" : "%Y-%m-%d %H:%M:%S") if pattern.nil?
    Time.new(parts[0], parts[1], parts[2], parts[3], parts[4], parts[5]).strftime(pattern)
  end

  def self.message(key, default, count)
    found = Rieles.translate("errors.messages." + key)
    (found.nil? ? default : found).gsub("%{count}", count)
  end

  def self.attribute_name(model, attribute)
    found = Rieles.translate("activerecord.attributes." + model + "." + attribute)
    found.nil? ? Rieles.humanize(attribute) : found
  end

  # Applies one db/migrate version unless schema_migrations has it.
  def self.migrate(version, name, statements)
    db = Rieles.db
    db.prepare("SELECT 1 FROM schema_migrations WHERE version = ?")
    db.bind_str(1, version)
    done = db.step == 1
    db.finalize
    return if done
    db.exec("BEGIN")
    statements.each do |statement|
      next if db.exec(statement)
      db.exec("ROLLBACK")
      $stderr.puts "rieles: migration " + version + " " + name + " failed at: " + statement
      exit(1)
    end
    db.prepare("INSERT INTO schema_migrations (version) VALUES (?)")
    db.bind_str(1, version)
    db.step
    db.finalize
    db.exec("COMMIT")
    puts "rieles: migrated " + version + " " + name
  end

  def self.latest_migration
    db = Rieles.db
    db.prepare("SELECT version FROM schema_migrations ORDER BY version DESC LIMIT 1")
    latest = db.step == 1 ? db.col_str(0) : ""
    db.finalize
    latest
  end

  def self.unapply(version, name, statements)
    db = Rieles.db
    db.exec("BEGIN")
    statements.each do |statement|
      next if db.exec(statement)
      db.exec("ROLLBACK")
      $stderr.puts "rieles: rolling back " + version + " " + name + " failed at: " + statement
      exit(1)
    end
    db.prepare("DELETE FROM schema_migrations WHERE version = ?")
    db.bind_str(1, version)
    db.step
    db.finalize
    db.exec("COMMIT")
    puts "rieles: rolled back " + version + " " + name
  end

  def self.irreversible(version, name)
    $stderr.puts "rieles: " + version + " " + name + " can't be rolled back; define up and down"
    exit(1)
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
        full = name == "base" ? message : Rieles.attribute_name(@model, name) + " " + message
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

  class Controller
    def initialize(req, res)
      @req = req
      @res = res
      @performed = false
      @response_body = ""
      @flash = Tep.str_hash
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

    def content_for_set(key, html)
      @content_for = Tep.str_hash if @content_for.nil?
      @content_for[key] = @content_for.fetch(key, "") + html
    end

    def content_for_get(key)
      return "" if @content_for.nil?
      @content_for.fetch(key, "")
    end

    def content_for?(key) = !content_for_get(key).empty?

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

    def cookie_set(key, value)
      opts = Tep.str_hash
      opts["Path"] = "/"
      opts["SameSite"] = "Lax"
      @res.set_cookie(key, value.to_s, opts)
    end

    def cookie_set_permanent(key, value)
      opts = Tep.str_hash
      opts["Path"] = "/"
      opts["SameSite"] = "Lax"
      opts["Max-Age"] = "630720000"
      @res.set_cookie(key, value.to_s, opts)
    end

    # value--hmac, verified with the session secret.
    def cookie_get_signed(key)
      raw = @req.cookies[key]
      return nil if raw.nil?
      cut = raw.rindex("--")
      return nil if cut.nil?
      value = raw[0, cut]
      Tep.timing_safe_eq(raw[cut + 2, raw.length - cut - 2], Crypto.sp_crypto_hmac_sha256_hex(Tep.session_secret, value)) ? value : nil
    end

    def cookie_set_signed(key, value)
      cookie_set(key, value.to_s + "--" + Crypto.sp_crypto_hmac_sha256_hex(Tep.session_secret, value.to_s))
    end

    def cookie_set_permanent_signed(key, value)
      cookie_set_permanent(key, value.to_s + "--" + Crypto.sp_crypto_hmac_sha256_hex(Tep.session_secret, value.to_s))
    end

    def cookie_delete(key)
      opts = Tep.str_hash
      opts["Path"] = "/"
      opts["Max-Age"] = "0"
      @res.set_cookie(key, "", opts)
    end

    # The best Accept-Language match among config/locales, or "".
    def locale_from_accept_language = Rieles.locale_from_header(@req.req_headers["accept-language"])

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

    def params = Parameters.new(@req.params, "")

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
      Rieles.log.redirect(location)
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

    def render_plain(text, status)
      @res.headers["Content-Type"] = "text/plain; charset=utf-8"
      render_html(text, status)
    end

    def h(value)
      Tep.h(value)
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
    def form_authenticity_token = @controller.form_authenticity_token
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
      delimiter = Rieles.translate("number.format.delimiter")
      separator = Rieles.translate("number.format.separator")
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
      unit = Rieles.translate("number.currency.format.unit") || unit if unit == "$"
      (number.to_f < 0 ? "-" : "") + unit + number_with_delimiter(amount)
    end

    # Timestamps are "YYYY-MM-DD HH:MM:SS" local time (see Rieles.now).
    def time_ago_in_words(timestamp)
      parts = timestamp.split(/[- :T]/).map { |x| x.to_i }
      return "" if parts.length < 6
      seconds = Time.now.to_i - Time.new(parts[0], parts[1], parts[2], parts[3], parts[4], parts[5]).to_i
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
