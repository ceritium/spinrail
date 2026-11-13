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
end

class Integer
  def to_json = to_s
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

  FILTERED_PARAMS = ["password", "token", "secret"].freeze

  def self.clock
    Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end

  # Collects one request's timings; subclasses decide how it is printed.
  # A worker serves one request at a time, so a single instance is enough.
  class Logger
    def initialize
      @color = $stdout.tty?
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
      @location = ""
      @error = ""
      @param_names = []
      @param_values = []
    end

    def start(verb, path, action, params)
      reset
      @started = Rieles.clock
      @verb = verb
      @path = path
      @action = action
      params.each do |name, value|
        @param_names << name
        @param_values << (filtered?(name) ? "[FILTERED]" : value.dup.force_encoding("UTF-8").scrub("?"))
      end
      on_start
    end

    def sql(name, statement, t0)
      ms = since(t0)
      @db += ms
      on_sql(name, statement, ms)
    end

    def render_start
      @depth += 1
      Rieles.clock
    end

    def render_end(template, t0)
      ms = since(t0)
      @depth -= 1
      @view += ms if @depth == 0
      on_render(template, ms)
    end

    def redirect(location)
      @location = location
      on_redirect
    end

    def error(e)
      @error = e.class.name + ": " + e.message
      on_error
    end

    def finish(status)
      on_finish(status, since(@started))
    end

    def on_start; end
    def on_sql(name, statement, elapsed); end
    def on_render(template, elapsed); end
    def on_redirect; end
    def on_error; end
    def on_finish(status, elapsed); end

    def since(t0) = (Rieles.clock - t0) * 1000.0
    def ms(value) = format("%.1f", value)
    def time = Time.now.strftime("%Y-%m-%dT%H:%M:%S%z")

    def filtered?(name)
      key = name.downcase
      FILTERED_PARAMS.any? { |f| key.include?(f) }
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
      puts ""
      puts "Started " + @verb + " " + @path.inspect + " at " + Time.now.strftime("%Y-%m-%d %H:%M:%S")
      puts "Processing by " + @action if @action.length > 0
      return if @param_names.empty?
      pairs = []
      i = 0
      while i < @param_names.length
        pairs << @param_names[i].inspect + " => " + @param_values[i].inspect
        i += 1
      end
      puts "  Parameters: {" + pairs.join(", ") + "}"
    end

    def on_sql(name, statement, elapsed)
      puts "  " + paint(name + " (" + ms(elapsed) + "ms)", "1;36") + "  " + paint(statement, "1;34")
    end

    def on_render(template, elapsed)
      puts "  Rendered " + template + " (" + ms(elapsed) + "ms)"
    end

    def on_redirect
      puts "Redirected to " + @location
    end

    def on_error
      puts paint("  " + @error, "1;31")
    end

    def on_finish(status, elapsed)
      line = "Completed " + status.to_s + " " + Tep.reason(status) + " in " + ms(elapsed) + "ms" \
             " (Views: " + ms(@view) + "ms | DB: " + ms(@db) + "ms)"
      puts paint(line, status >= 500 ? "1;31" : (status >= 400 ? "1;33" : "1;32"))
    end
  end

  # One line per request: key=value, quoted when needed.
  class LogfmtLogger < Logger
    def on_finish(status, elapsed)
      line = "time=" + time + " method=" + @verb + " path=" + value(@path)
      line = line + " action=" + value(@action) if @action.length > 0
      line = line + " status=" + status.to_s + " duration_ms=" + ms(elapsed) +
             " view_ms=" + ms(@view) + " db_ms=" + ms(@db)
      line = line + " location=" + value(@location) if @location.length > 0
      line = line + " error=" + value(@error) if @error.length > 0
      puts line
    end

    def value(text)
      return text unless text.empty? || text.include?(" ") || text.include?("=") || text.include?("\"")
      "\"" + escape(text) + "\""
    end
  end

  # One JSON object per request.
  class JsonLogger < Logger
    def on_finish(status, elapsed)
      fields = ["\"time\":" + str(time), "\"method\":" + str(@verb), "\"path\":" + str(@path)]
      fields << "\"action\":" + str(@action) if @action.length > 0
      fields << "\"status\":" + status.to_s
      fields << "\"duration_ms\":" + ms(elapsed)
      fields << "\"view_ms\":" + ms(@view)
      fields << "\"db_ms\":" + ms(@db)
      fields << "\"location\":" + str(@location) if @location.length > 0
      fields << "\"error\":" + str(@error) if @error.length > 0
      puts "{" + fields.join(",") + "}"
    end

    def str(text)
      "\"" + escape(text) + "\""
    end
  end

  def self.build_logger
    format = ENV.fetch("RIELES_LOG_FORMAT", "dev")
    return LogfmtLogger.new if format == "logfmt"
    return JsonLogger.new if format == "json"
    DevLogger.new
  end

  LOG = build_logger

  def self.log = LOG

  def self.env = ENV.fetch("RIELES_ENV", "development")

  # Off in tests unless a test asks for it, as in Rails.
  def self.forgery_protection?
    ENV.fetch("RIELES_FORGERY_PROTECTION", Rieles.env == "test" ? "0" : "1") == "1"
  end

  def self.database_path
    ENV.fetch("DATABASE_PATH", "./db/development.sqlite3")
  end

  class RecordInvalid < StandardError; end
  class StatementInvalid < StandardError; end

  # One connection per process. Tep::SQLite has a single cursor, which is
  # fine because relations load every row before handing any out.
  class Database
    def initialize
      @conn = Tep::SQLite.new
      @open = false
    end

    def connection
      return @conn if @open
      raise StatementInvalid, "can't open " + Rieles.database_path unless @conn.open(Rieles.database_path)
      @open = true
      @conn
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

  def self.transaction
    db = Rieles.db
    db.exec("BEGIN")
    begin
      result = yield
      db.exec("COMMIT")
      result
    rescue StandardError => e
      db.exec("ROLLBACK")
      raise e
    end
  end

  def self.humanize(attribute)
    attribute.sub(/_id\z/, "").tr("_", " ").capitalize
  end

  class Record
  end

  class Errors
    def initialize
      @attributes = []
      @messages = []
      @full_messages = []
    end

    def add(attribute, message, full_message = "")
      name = attribute.to_s
      full = full_message
      if full.empty?
        full = name == "base" ? message : Rieles.humanize(name) + " " + message
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
    def flash_get(key) = @controller.flash_get(key)
    def notice = @controller.flash_get("notice")
    def alert = @controller.flash_get("alert")
    def session_get(key) = @controller.session_get(key)
    def form_authenticity_token = @controller.form_authenticity_token

    def csrf_meta_tags
      "<meta name=\"csrf-param\" content=\"authenticity_token\">\n" \
        "<meta name=\"csrf-token\" content=\"" + h(form_authenticity_token) + "\">"
    end

    def h(value)
      Tep.h(value)
    end

    def pluralize(count, singular)
      count.to_s + " " + (count == 1 ? singular : singular + "s")
    end
  end
end
