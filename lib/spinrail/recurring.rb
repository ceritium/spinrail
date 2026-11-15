module Spinrail
  # config/recurring.yml, as Solid Queue reads it: tasks under an
  # environment's key (or at the top, for every environment), each with
  # class: (and args:) or command:, schedule:, and queue:/priority:.
  # Schedules are five-field cron or a few of Fugit's phrasings; both turn
  # into Ruby that answers which run a time falls in.
  class Recurring
    Task = Struct.new(:key, :env, :job, :args, :command, :queue, :priority, :slot)

    TASK_KEYS = %w[class args command schedule queue priority description].freeze
    UNITS = { "second" => 1, "minute" => 60, "hour" => 3600 }.freeze
    DAYS = %w[sun mon tue wed thu fri sat].freeze
    MONTHS = %w[jan feb mar apr may jun jul aug sep oct nov dec].freeze
    FIELDS = [["min", 0, 59], ["hour", 0, 23], ["day", 1, 31], ["month", 1, 12], ["wday", 0, 6]].freeze

    attr_reader :tasks

    def initialize(file)
      @file = File.basename(File.dirname(file)) + "/" + File.basename(file)
      config = File.exist?(file) ? YAML.safe_load_file(file, aliases: true) || {} : {}
      raise CompileError, "#{@file}: expected a mapping" unless config.is_a?(Hash)
      @tasks = config.flat_map do |key, value|
        raise CompileError, "#{@file}: #{key} isn't a task or an environment" unless value.is_a?(Hash)
        if task?(value)
          [task(key, "", value)]
        else
          value.map do |k, v|
            raise CompileError, "#{@file}: #{key}.#{k} isn't a task" unless v.is_a?(Hash) && task?(v)
            task(k, key.to_s, v)
          end
        end
      end
    end

    def task?(hash) = hash.key?("schedule") || hash.key?("class") || hash.key?("command")

    def task(key, env, h)
      where = "#{@file}: #{key}"
      unknown = h.keys - TASK_KEYS
      raise CompileError, "#{where}: unknown #{unknown.join(', ')}" if unknown.any?
      raise CompileError, "#{where}: needs a schedule" unless h["schedule"]
      raise CompileError, "#{where}: needs class: or command:" unless h["class"].nil? ^ h["command"].nil?
      args = h["args"].nil? ? [] : Array(h["args"])
      raise CompileError, "#{where}: args are plain values" if args.any? { |a| a.is_a?(Hash) || a.is_a?(Array) }
      raise CompileError, "#{where}: priority is an integer" unless h["priority"].nil? || h["priority"].is_a?(Integer)
      Task.new(key.to_s, env, h["class"]&.to_s, args.map(&:to_s), h["command"]&.to_s, h["queue"].to_s, h["priority"] || -1,
               slot(h["schedule"].to_s, where))
    end

    # The Ruby for "the run t falls in": a minute for cron, an interval's
    # start for every N seconds.
    def slot(schedule, where)
      text = schedule.strip.downcase.squeeze(" ")
      if (m = text.match(/\Aevery (\d+ )?(second|minute|hour)s?\z/))
        n = (m[1] || 1).to_i
        raise CompileError, "#{where}: every 0 #{m[2]}s" if n.zero?
        return "Spinrail::Jobs.interval_slot(t, #{n * UNITS[m[2]]})" if m[2] == "second" || 86_400 % (n * UNITS[m[2]]) != 0
        return cron(m[2] == "minute" ? "*/#{n} * * * *" : "0 */#{n} * * *", where)
      end
      if (m = text.match(/\A(?:every day at (.+)|at (.+) every day|every day)\z/))
        h, min = m[1] || m[2] ? clock(m[1] || m[2], where) : [0, 0]
        return cron("#{min} #{h} * * *", where)
      end
      if (m = text.match(/\Aevery (#{DAYS.join('|')})[a-z]*(?: at (.+))?\z/))
        h, min = m[2] ? clock(m[2], where) : [0, 0]
        return cron("#{min} #{h} * * #{DAYS.index(m[1])}", where)
      end
      cron(text, where)
    end

    # 5am, 5:30pm, 17:30, noon, midnight.
    def clock(text, where)
      return [12, 0] if text == "noon"
      return [0, 0] if text == "midnight"
      m = text.match(/\A(\d{1,2})(?::(\d{2}))?\s*(am|pm)?\z/) or raise CompileError, "#{where}: can't read the time #{text.inspect}"
      h = m[1].to_i
      h = h % 12 + (m[3] == "pm" ? 12 : 0) if m[3]
      raise CompileError, "#{where}: can't read the time #{text.inspect}" if h > 23 || m[2].to_i > 59
      [h, m[2].to_i]
    end

    def cron(text, where)
      parts = text.split
      raise CompileError, "#{where}: schedule #{text.inspect} is neither cron (5 fields) nor every N minutes/hours, every day at 5am" unless parts.size == 5
      sets = parts.each_with_index.map { |part, i| field(part, *FIELDS[i][1..], i, where) }
      checks = [0, 1, 3].filter_map { |i| "#{sets[i].inspect}.include?(t.#{FIELDS[i][0]})" if sets[i] }
      day, wday = sets[2], sets[4]
      # Cron: with both day of month and day of week restricted, either matches.
      if day && wday
        checks << "(#{day.inspect}.include?(t.day) || #{wday.inspect}.include?(t.wday))"
      elsif day || wday
        checks << (day ? "#{day.inspect}.include?(t.day)" : "#{wday.inspect}.include?(t.wday)")
      end
      checks.empty? ? "Spinrail::Jobs.minute_slot(t)" : "(#{checks.join(' && ')} ? Spinrail::Jobs.minute_slot(t) : \"\")"
    end

    # nil for *; otherwise the values allowed.
    def field(part, low, high, index, where)
      return nil if part == "*"
      names = index == 4 ? DAYS : (index == 3 ? MONTHS : [])
      values = part.split(",").flat_map do |item|
        range, step = item.split("/", 2)
        first, last = if range == "*" then [low, high]
                      elsif range.include?("-") then range.split("-", 2).map { |v| number(v, names, low, where) }
                      else
                        v = number(range, names, low, where)
                        [v, step ? (index == 4 ? 6 : high) : v]
                      end
        top = index == 4 ? 7 : high # 7 is Sunday too
        raise CompileError, "#{where}: #{part.inspect} is out of #{low}-#{high}" unless first.between?(low, top) && last.between?(low, top) && first <= last
        (first..last).step(step ? step.to_i : 1).to_a
      end
      values = values.map { |v| index == 4 ? v % 7 : v }.uniq.sort
      values == (low..high).to_a ? nil : values
    end

    def number(text, names, low, where)
      return names.index(text[0, 3]) + (names.equal?(MONTHS) ? 1 : 0) if names.include?(text[0, 3])
      raise CompileError, "#{where}: can't read #{text.inspect} in the schedule" unless text.match?(/\A\d+\z/)
      text.to_i
    end
  end
end

module Spinrail
  class Recurring
    # SpinrailRecurring: keys, environments, slot(i, t) and fire(i, at);
    # command: tasks become methods, lowered like app code, run as jobs
    # named SpinrailRecurring/<key>.
    def to_ruby
      fire = @tasks.each_with_index.map do |t, i|
        name = t.job || "SpinrailRecurring/#{t.key}"
        list = t.args.empty? ? "Spinrail.no_binds" : t.args.inspect
        queue = t.job ? t.queue : (t.queue.empty? ? "default" : t.queue)
        priority = t.job ? t.priority : [t.priority, 0].max
        "    return Spinrail::Jobs.recur(#{t.key.inspect}, at, #{name.inspect}, #{list}, #{queue.inspect}, #{priority}) if i == #{i}"
      end
      commands = @tasks.each_with_index.select { |t, _| t.command }.map { |t, i| "  def self.command_#{i}\n#{t.command.gsub(/^/, '    ')}\n    nil\n  end" }
      <<~RUBY
        module SpinrailRecurring
          def self.keys = #{@tasks.empty? ? 'Spinrail.no_binds' : @tasks.map(&:key).inspect}
          def self.envs = #{@tasks.empty? ? 'Spinrail.no_binds' : @tasks.map(&:env).inspect}

          def self.slot(i, t)
        #{@tasks.each_with_index.map { |t, i| "    return #{t.slot} if i == #{i}" }.join("\n")}
            ""
          end

          def self.fire(i, at)
        #{fire.join("\n")}
            nil
          end

        #{commands.join("\n\n")}
        end
      RUBY
    end

    def dispatch
      @tasks.each_with_index.select { |t, _| t.command }.map do |t, i|
        "    return SpinrailRecurring.command_#{i} if name == #{"SpinrailRecurring/#{t.key}".inspect}"
      end
    end
  end
end
