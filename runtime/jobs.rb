# Background jobs on Solid Queue's model: a job row, plus one execution row
# for where it is (scheduled, ready, claimed or failed). Times are TEXT as
# Spinrail.format_time writes them, so they compare as strings.
module Spinrail
  class Job
    def perform(arg)
      "" + arg
    end
  end

  module Jobs
    SCHEMA = [
      "CREATE TABLE IF NOT EXISTS spinrail_queue_jobs (id INTEGER PRIMARY KEY, queue_name TEXT NOT NULL, " \
      "class_name TEXT NOT NULL, arguments TEXT NOT NULL, priority INTEGER NOT NULL DEFAULT 0, " \
      "executions INTEGER NOT NULL DEFAULT 0, scheduled_at TEXT NOT NULL DEFAULT '', finished_at TEXT NOT NULL DEFAULT '', created_at TEXT NOT NULL, " \
      "updated_at TEXT NOT NULL)",
      "CREATE INDEX IF NOT EXISTS index_spinrail_queue_jobs_on_class_name ON spinrail_queue_jobs (class_name)",
      "CREATE INDEX IF NOT EXISTS index_spinrail_queue_jobs_on_finished_at ON spinrail_queue_jobs (finished_at)",
      "CREATE TABLE IF NOT EXISTS spinrail_queue_ready_executions (id INTEGER PRIMARY KEY, job_id INTEGER NOT NULL, " \
      "queue_name TEXT NOT NULL, priority INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL)",
      "CREATE UNIQUE INDEX IF NOT EXISTS index_spinrail_queue_ready_executions_on_job_id ON spinrail_queue_ready_executions (job_id)",
      "CREATE INDEX IF NOT EXISTS index_spinrail_queue_poll_all ON spinrail_queue_ready_executions (priority, job_id)",
      "CREATE INDEX IF NOT EXISTS index_spinrail_queue_poll_by_queue ON spinrail_queue_ready_executions (queue_name, priority, job_id)",
      "CREATE TABLE IF NOT EXISTS spinrail_queue_scheduled_executions (id INTEGER PRIMARY KEY, job_id INTEGER NOT NULL, " \
      "queue_name TEXT NOT NULL, priority INTEGER NOT NULL DEFAULT 0, scheduled_at TEXT NOT NULL, created_at TEXT NOT NULL)",
      "CREATE UNIQUE INDEX IF NOT EXISTS index_spinrail_queue_scheduled_executions_on_job_id ON spinrail_queue_scheduled_executions (job_id)",
      "CREATE INDEX IF NOT EXISTS index_spinrail_queue_dispatch_all ON spinrail_queue_scheduled_executions (scheduled_at, priority, job_id)",
      "CREATE TABLE IF NOT EXISTS spinrail_queue_claimed_executions (id INTEGER PRIMARY KEY, job_id INTEGER NOT NULL, " \
      "process_id INTEGER NOT NULL DEFAULT 0, created_at TEXT NOT NULL)",
      "CREATE UNIQUE INDEX IF NOT EXISTS index_spinrail_queue_claimed_executions_on_job_id ON spinrail_queue_claimed_executions (job_id)",
      "CREATE INDEX IF NOT EXISTS index_spinrail_queue_claimed_on_process ON spinrail_queue_claimed_executions (process_id, job_id)",
      "CREATE TABLE IF NOT EXISTS spinrail_queue_failed_executions (id INTEGER PRIMARY KEY, job_id INTEGER NOT NULL, " \
      "error TEXT NOT NULL, created_at TEXT NOT NULL)",
      "CREATE UNIQUE INDEX IF NOT EXISTS index_spinrail_queue_failed_executions_on_job_id ON spinrail_queue_failed_executions (job_id)"
    ].freeze

    def self.schema
      SCHEMA.each { |sql| Spinrail.db.exec(sql) }
    end

    # What SpinrailJobs.retry_wait answers when the job shouldn't be retried
    # (otherwise the seconds to wait).
    FAIL = -1
    DISCARD = -2

    def self.inline? = ENV.fetch("SPINRAIL_JOBS_INLINE", Spinrail.env == "test" ? "1" : "0") == "1"

    def self.now = Spinrail.format_time(Spinrail.now)

    # XJob.set(queue:, priority:, wait:, wait_until:).perform_later(*args).
    # Empty queue and priority -1 take the job's queue_as and
    # queue_with_priority; empty at means now. Tests run jobs right away
    # unless SPINRAIL_JOBS_INLINE=0.
    def self.enqueue(name, args, queue, priority, at)
      if Jobs.inline?
        Jobs.perform_inline(name, args)
        return 0
      end
      queue_name = queue.empty? ? SpinrailJobs.queue_for(name) : queue
      prio = priority < 0 ? SpinrailJobs.priority_for(name) : priority
      Spinrail.transaction { Jobs.insert(name, Jobs.encode(args), queue_name, prio, at, 0) }
    end

    # retry_on retries right away and discard_on swallows, as a worker would
    # but without waiting.
    def self.perform_inline(name, args)
      executions = 1
      loop do
        begin
          SpinrailJobs.dispatch(name, args)
          return
        rescue StandardError => e
          wait = SpinrailJobs.retry_wait(name, e, executions)
          return if wait == DISCARD
          raise e if wait == FAIL
          executions += 1
        end
      end
    end

    def self.insert(name, arguments, queue_name, prio, at, executions)
      now = Jobs.now
      scheduled = at.empty? ? now : at
      db = Spinrail.prepare("INSERT INTO spinrail_queue_jobs (queue_name, class_name, arguments, priority, executions, scheduled_at, created_at, updated_at) " \
                            "VALUES (?, ?, ?, ?, ?, ?, ?, ?)", true)
      db.bind_str(1, queue_name)
      db.bind_str(2, name)
      db.bind_str(3, arguments)
      db.bind_int(4, prio)
      db.bind_int(5, executions)
      db.bind_str(6, scheduled)
      db.bind_str(7, now)
      db.bind_str(8, now)
      db.step
      db.finalize
      id = db.last_rowid
      if scheduled > now
        Jobs.insert_execution("INSERT INTO spinrail_queue_scheduled_executions (job_id, queue_name, priority, scheduled_at, created_at) " \
                              "VALUES (?, ?, ?, ?, ?)", id, queue_name, prio, scheduled)
      else
        Jobs.insert_execution("INSERT INTO spinrail_queue_ready_executions (job_id, queue_name, priority, created_at) VALUES (?, ?, ?, ?)",
                              id, queue_name, prio, "")
      end
      id
    end

    def self.insert_execution(sql, id, queue_name, prio, scheduled)
      db = Spinrail.prepare(sql, true)
      db.bind_int(1, id)
      db.bind_str(2, queue_name)
      db.bind_int(3, prio)
      if scheduled.empty?
        db.bind_str(4, Jobs.now)
      else
        db.bind_str(4, scheduled)
        db.bind_str(5, Jobs.now)
      end
      db.step
      db.finalize
    end

    # Arguments are a JSON array of Strings, as Tep::Json writes them (\u only
    # for control bytes).
    def self.encode(args) = Tep::Json.from_str_array(args)

    def self.decode(text)
      out = [""]
      out.clear
      i = 0
      n = text.length
      while i < n
        if text[i] == "\""
          value = +""
          i += 1
          while i < n && text[i] != "\""
            c = text[i]
            if c == "\\" && i + 1 < n
              i += 1
              e = text[i]
              if e == "n"
                value << "\n"
              elsif e == "t"
                value << "\t"
              elsif e == "r"
                value << "\r"
              elsif e == "b"
                value << "\b"
              elsif e == "f"
                value << "\f"
              elsif e == "u" && i + 4 < n
                value << text[i + 1, 4].to_i(16).chr
                i += 4
              else
                value << e
              end
            else
              value << c
            end
            i += 1
          end
          out << value
        end
        i += 1
      end
      out
    end

    # The argument at i, or "" when the job was enqueued with fewer.
    def self.arg(args, i) = i < args.length ? args[i] : ""

    # Moves due scheduled executions to ready. Several dispatchers may race:
    # the unique job_id index keeps one ready row per job.
    def self.dispatch_scheduled
      now = Jobs.now
      db = Spinrail.prepare("SELECT 1 FROM spinrail_queue_scheduled_executions WHERE scheduled_at <= ? LIMIT 1", true)
      db.bind_str(1, now)
      due = db.step == 1
      db.finalize
      return unless due
      return unless Spinrail.db.exec("BEGIN IMMEDIATE")
      db = Spinrail.prepare("INSERT INTO spinrail_queue_ready_executions (job_id, queue_name, priority, created_at) " \
                            "SELECT job_id, queue_name, priority, ? FROM spinrail_queue_scheduled_executions WHERE scheduled_at <= ? " \
                            "ON CONFLICT DO NOTHING", true)
      db.bind_str(1, now)
      db.bind_str(2, now)
      db.step
      db.finalize
      db = Spinrail.prepare("DELETE FROM spinrail_queue_scheduled_executions WHERE scheduled_at <= ?", true)
      db.bind_str(1, now)
      db.step
      db.finalize
      Spinrail.db.exec("COMMIT")
    end

    # "*" polls every queue by priority; otherwise queues in the order
    # given, "name*" matching a prefix.
    def self.poll_sql(queue)
      sql = "SELECT job_id FROM spinrail_queue_ready_executions"
      if queue.end_with?("*") && queue != "*"
        sql += " WHERE queue_name LIKE '" + queue.delete_suffix("*").gsub("'", "''") + "%'"
      elsif queue != "*"
        sql += " WHERE queue_name = '" + queue.gsub("'", "''") + "'"
      end
      sql + " ORDER BY priority, job_id LIMIT 1 /*SKIP LOCKED*/"
    end

    # Claims the next ready job, moving its execution to claimed inside one
    # transaction so two workers can't take it. Returns the job id or 0.
    def self.claim(queues, process_id)
      queues.each do |queue|
        sql = Jobs.poll_sql(queue)
        db = Spinrail.prepare(sql.delete_suffix(" /*SKIP LOCKED*/"), false)
        ready = db.step == 1
        db.finalize
        next unless ready
        # Busy past busy_timeout: claim nothing rather than race outside a transaction.
        return 0 unless Spinrail.db.exec("BEGIN IMMEDIATE")
        db = Spinrail.prepare(sql, false)
        id = db.step == 1 ? db.col_int(0) : 0
        db.finalize
        if id > 0
          db = Spinrail.prepare("DELETE FROM spinrail_queue_ready_executions WHERE job_id = ?", true)
          db.bind_int(1, id)
          db.step
          db.finalize
          db = Spinrail.prepare("INSERT INTO spinrail_queue_claimed_executions (job_id, process_id, created_at) VALUES (?, ?, ?)", true)
          db.bind_int(1, id)
          db.bind_int(2, process_id)
          db.bind_str(3, Jobs.now)
          db.step
          db.finalize
        end
        Spinrail.db.exec("COMMIT")
        return id if id > 0
      end
      0
    end

    # Claims and performs one job; false when none was ready. As in Active
    # Job, a retry is a new job with one more execution, and the failed one
    # is finished.
    def self.work_one(queues, process_id)
      id = Jobs.claim(queues, process_id)
      return false if id == 0
      db = Spinrail.prepare("SELECT class_name, arguments, queue_name, priority, executions FROM spinrail_queue_jobs WHERE id = ?", true)
      db.bind_int(1, id)
      name = ""
      arguments = "[]"
      queue_name = ""
      prio = 0
      executions = 1
      if db.step == 1
        name = db.col_str(0)
        arguments = db.col_str(1)
        queue_name = db.col_str(2)
        prio = db.col_int(3)
        executions = db.col_int(4) + 1
      end
      db.finalize
      t0 = Spinrail.clock
      begin
        SpinrailJobs.dispatch(name, Jobs.decode(arguments))
        Jobs.finish(id)
        Spinrail.say("Performed " + name + " #" + id.to_s + " in " + format("%.1f", (Spinrail.clock - t0) * 1000.0) + "ms")
      rescue StandardError => e
        wait = SpinrailJobs.retry_wait(name, e, executions)
        if wait == DISCARD
          Jobs.finish(id)
          Spinrail.say("Discarded " + name + " #" + id.to_s + ": " + e.message)
        elsif wait == FAIL
          Jobs.fail(id, e.class.name + ": " + e.message)
          Spinrail.say("Failed " + name + " #" + id.to_s + ": " + e.message)
        else
          at = Spinrail.format_time(Time.now + wait)
          Spinrail.transaction do
            Jobs.finish(id)
            Jobs.insert(name, arguments, queue_name, prio, wait > 0 ? at : "", executions)
          end
          Spinrail.say("Failed " + name + " #" + id.to_s + ": " + e.message + " (retrying in " + wait.to_s + "s)")
        end
      end
      true
    end

    def self.finish(id)
      Spinrail.transaction do
        Jobs.release(id)
        db = Spinrail.prepare("UPDATE spinrail_queue_jobs SET finished_at = ?, updated_at = ? WHERE id = ?", true)
        now = Jobs.now
        db.bind_str(1, now)
        db.bind_str(2, now)
        db.bind_int(3, id)
        db.step
        db.finalize
      end
    end

    def self.fail(id, error)
      Spinrail.transaction do
        Jobs.release(id)
        db = Spinrail.prepare("INSERT INTO spinrail_queue_failed_executions (job_id, error, created_at) VALUES (?, ?, ?)", true)
        db.bind_int(1, id)
        db.bind_str(2, error)
        db.bind_str(3, Jobs.now)
        db.step
        db.finalize
      end
    end

    def self.release(id)
      db = Spinrail.prepare("DELETE FROM spinrail_queue_claimed_executions WHERE job_id = ?", true)
      db.bind_int(1, id)
      db.step
      db.finalize
    end

    def self.queues = ENV.fetch("SPINRAIL_JOBS_QUEUES", "*").split(",").map { |q| q.strip }.reject { |q| q.empty? }

    def self.polling_interval = ENV.fetch("SPINRAIL_JOBS_POLLING_INTERVAL", "0.1").to_f

    # One worker's loop: dispatch due scheduled jobs at most once a second,
    # then perform ready ones, sleeping polling_interval when idle.
    def self.work(process_id)
      queues = Jobs.queues
      interval = Jobs.polling_interval
      dispatched = 0.0
      loop do
        if Spinrail.clock - dispatched >= 1.0
          Jobs.dispatch_scheduled
          dispatched = Spinrail.clock
        end
        sleep interval unless Jobs.work_one(queues, process_id)
      end
    end

    def self.start
      puts "spinrail: working jobs on " + Jobs.queues.join(",") + " (Ctrl+C to stop)"
      $stdout.flush
      Jobs.work(0)
    end
  end
end
