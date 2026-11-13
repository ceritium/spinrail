# Compiled into every app by spinel. Everything app-specific (models,
# path helpers, views) is generated around these classes at build time.
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
