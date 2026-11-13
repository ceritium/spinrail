# Compiled into every app by spinel. Everything app-specific (models,
# path helpers, views) is generated around these classes at build time.

# tep's table only knows 12 codes and answers "OK" for the rest (303 OK,
# 422 OK). An empty reason phrase is valid HTTP/1.1 (RFC 9112 §4).
module Tep
  def self.reason(status)
    return "OK" if status == 200
    return "Created" if status == 201
    return "Accepted" if status == 202
    return "No Content" if status == 204
    return "Partial Content" if status == 206
    return "Moved Permanently" if status == 301
    return "Found" if status == 302
    return "See Other" if status == 303
    return "Not Modified" if status == 304
    return "Temporary Redirect" if status == 307
    return "Permanent Redirect" if status == 308
    return "Bad Request" if status == 400
    return "Unauthorized" if status == 401
    return "Forbidden" if status == 403
    return "Not Found" if status == 404
    return "Method Not Allowed" if status == 405
    return "Conflict" if status == 409
    return "Gone" if status == 410
    return "Content Too Large" if status == 413
    return "Unsupported Media Type" if status == 415
    return "Unprocessable Content" if status == 422
    return "Too Many Requests" if status == 429
    return "Internal Server Error" if status == 500
    return "Not Implemented" if status == 501
    return "Bad Gateway" if status == 502
    return "Service Unavailable" if status == 503
    return "Gateway Timeout" if status == 504
    ""
  end
end

module Rieles
  class RecordNotFound < StandardError; end

  def self.database_path
    ENV.fetch("DATABASE_PATH", "./db/development.sqlite3")
  end

  def self.connect
    db = Tep::SQLite.new
    db.open(database_path)
    db
  end

  class Record
  end

  class Errors
    def initialize
      @attributes = []
      @messages = []
      @full_messages = []
    end

    def add(attribute, message, full_message)
      @attributes << attribute
      @messages << message
      @full_messages << full_message
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
    end

    def performed?
      @performed
    end

    def response_body
      @response_body
    end

    # Form params arrive as ASCII-8BIT, and a missing one as a frozen "".
    def param(name)
      Tep.param(@req, name).dup.force_encoding("UTF-8").scrub("")
    end

    def redirect_to(location, status)
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
    def h(value)
      Tep.h(value)
    end

    def pluralize(count, singular)
      count.to_s + " " + (count == 1 ? singular : singular + "s")
    end
  end
end
