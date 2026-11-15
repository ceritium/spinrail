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
      "executions INTEGER NOT NULL DEFAULT 0, concurrency_key TEXT NOT NULL DEFAULT '', " \
      "scheduled_at TEXT NOT NULL DEFAULT '', finished_at TEXT NOT NULL DEFAULT '', created_at TEXT NOT NULL, " \
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
      "CREATE UNIQUE INDEX IF NOT EXISTS index_spinrail_queue_failed_executions_on_job_id ON spinrail_queue_failed_executions (job_id)",
      "CREATE TABLE IF NOT EXISTS spinrail_queue_processes (id INTEGER PRIMARY KEY, kind TEXT NOT NULL, name TEXT NOT NULL, " \
      "pid INTEGER NOT NULL, hostname TEXT NOT NULL DEFAULT '', metadata TEXT NOT NULL DEFAULT '', " \
      "last_heartbeat_at TEXT NOT NULL, created_at TEXT NOT NULL)",
      "CREATE INDEX IF NOT EXISTS index_spinrail_queue_processes_on_last_heartbeat_at ON spinrail_queue_processes (last_heartbeat_at)",
      "CREATE TABLE IF NOT EXISTS spinrail_queue_pauses (id INTEGER PRIMARY KEY, queue_name TEXT NOT NULL, created_at TEXT NOT NULL)",
      "CREATE UNIQUE INDEX IF NOT EXISTS index_spinrail_queue_pauses_on_queue_name ON spinrail_queue_pauses (queue_name)",
      "CREATE TABLE IF NOT EXISTS spinrail_queue_semaphores (id INTEGER PRIMARY KEY, key TEXT NOT NULL, value INTEGER NOT NULL DEFAULT 1, " \
      "expires_at TEXT NOT NULL, created_at TEXT NOT NULL, updated_at TEXT NOT NULL)",
      "CREATE UNIQUE INDEX IF NOT EXISTS index_spinrail_queue_semaphores_on_key ON spinrail_queue_semaphores (key)",
      "CREATE INDEX IF NOT EXISTS index_spinrail_queue_semaphores_on_expires_at ON spinrail_queue_semaphores (expires_at)",
      "CREATE TABLE IF NOT EXISTS spinrail_queue_blocked_executions (id INTEGER PRIMARY KEY, job_id INTEGER NOT NULL, " \
      "queue_name TEXT NOT NULL, priority INTEGER NOT NULL DEFAULT 0, concurrency_key TEXT NOT NULL, expires_at TEXT NOT NULL, created_at TEXT NOT NULL)",
      "CREATE UNIQUE INDEX IF NOT EXISTS index_spinrail_queue_blocked_executions_on_job_id ON spinrail_queue_blocked_executions (job_id)",
      "CREATE INDEX IF NOT EXISTS index_spinrail_queue_blocked_for_release ON spinrail_queue_blocked_executions (concurrency_key, priority, job_id)",
      "CREATE INDEX IF NOT EXISTS index_spinrail_queue_blocked_for_maintenance ON spinrail_queue_blocked_executions (expires_at, concurrency_key)",
      "CREATE TABLE IF NOT EXISTS spinrail_queue_recurring_executions (id INTEGER PRIMARY KEY, job_id INTEGER NOT NULL, " \
      "task_key TEXT NOT NULL, run_at TEXT NOT NULL, created_at TEXT NOT NULL)",
      "CREATE UNIQUE INDEX IF NOT EXISTS index_spinrail_queue_recurring_executions_on_task_key_and_run_at " \
      "ON spinrail_queue_recurring_executions (task_key, run_at)"
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
      key = SpinrailJobs.concurrency_key(name, args)
      Spinrail.transaction { Jobs.insert(name, Jobs.encode(args), queue_name, prio, at, 0, key) }
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

    def self.insert(name, arguments, queue_name, prio, at, executions, key)
      now = Jobs.now
      scheduled = at.empty? ? now : at
      db = Spinrail.prepare("INSERT INTO spinrail_queue_jobs (queue_name, class_name, arguments, priority, executions, scheduled_at, created_at, " \
                            "updated_at, concurrency_key) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)", true)
      db.bind_str(1, queue_name)
      db.bind_str(2, name)
      db.bind_str(3, arguments)
      db.bind_int(4, prio)
      db.bind_int(5, executions)
      db.bind_str(6, scheduled)
      db.bind_str(7, now)
      db.bind_str(8, now)
      db.bind_str(9, key)
      db.step
      db.finalize
      id = db.last_rowid
      if scheduled > now
        Jobs.insert_execution("INSERT INTO spinrail_queue_scheduled_executions (job_id, queue_name, priority, scheduled_at, created_at) " \
                              "VALUES (?, ?, ?, ?, ?)", id, queue_name, prio, scheduled)
      else
        Jobs.make_ready(id, name, key, queue_name, prio)
      end
      id
    end

    # limits_concurrency: a job with a key runs only while it holds its
    # key's semaphore; otherwise it waits blocked (or is discarded, with
    # on_conflict: :discard) until a job with that key ends or the
    # semaphore expires, as in Solid Queue.
    def self.make_ready(id, name, key, queue_name, prio)
      if key.empty? || Jobs.acquire(name, key)
        Jobs.insert_execution("INSERT INTO spinrail_queue_ready_executions (job_id, queue_name, priority, created_at) VALUES (?, ?, ?, ?)",
                              id, queue_name, prio, "")
      elsif SpinrailJobs.concurrency_discard(name)
        Jobs.mark_finished(id)
      else
        db = Spinrail.prepare("INSERT INTO spinrail_queue_blocked_executions (job_id, queue_name, priority, concurrency_key, expires_at, created_at) " \
                              "VALUES (?, ?, ?, ?, ?, ?)", true)
        db.bind_int(1, id)
        db.bind_str(2, queue_name)
        db.bind_int(3, prio)
        db.bind_str(4, key)
        db.bind_str(5, Jobs.expiry(name))
        db.bind_str(6, Jobs.now)
        db.step
        db.finalize
      end
    end

    def self.expiry(name) = Spinrail.format_time(Time.now + SpinrailJobs.concurrency_duration(name))

    # The semaphore starts at the limit; RETURNING says whether a slot was taken.
    def self.acquire(name, key)
      now = Jobs.now
      db = Spinrail.prepare("INSERT INTO spinrail_queue_semaphores (key, value, expires_at, created_at, updated_at) VALUES (?, ?, ?, ?, ?) " \
                            "ON CONFLICT DO NOTHING", true)
      db.bind_str(1, key)
      db.bind_int(2, SpinrailJobs.concurrency_limit(name))
      db.bind_str(3, Jobs.expiry(name))
      db.bind_str(4, now)
      db.bind_str(5, now)
      db.step
      db.finalize
      db = Spinrail.prepare("UPDATE spinrail_queue_semaphores SET value = value - 1, expires_at = ?, updated_at = ? " \
                            "WHERE key = ? AND value > 0 RETURNING value", true)
      db.bind_str(1, Jobs.expiry(name))
      db.bind_str(2, now)
      db.bind_str(3, key)
      taken = db.step == 1
      db.finalize
      taken
    end

    # A job with a key ended: give its slot back and let the next blocked one in.
    def self.signal(name, key)
      return if key.empty?
      db = Spinrail.prepare("UPDATE spinrail_queue_semaphores SET value = value + 1, updated_at = ? WHERE key = ? AND value < ?", true)
      db.bind_str(1, Jobs.now)
      db.bind_str(2, key)
      db.bind_int(3, SpinrailJobs.concurrency_limit(name))
      db.step
      db.finalize
      Jobs.unblock(key)
    end

    def self.unblock(key)
      db = Spinrail.prepare("SELECT b.job_id, j.class_name, b.queue_name, b.priority FROM spinrail_queue_blocked_executions b " \
                            "JOIN spinrail_queue_jobs j ON j.id = b.job_id WHERE b.concurrency_key = ? ORDER BY b.priority, b.job_id LIMIT 1", true)
      db.bind_str(1, key)
      found = db.step == 1
      id = found ? db.col_int(0) : 0
      name = found ? db.col_str(1) : ""
      queue_name = found ? db.col_str(2) : ""
      prio = found ? db.col_int(3) : 0
      db.finalize
      return unless found && Jobs.acquire(name, key)
      Jobs.delete_where("DELETE FROM spinrail_queue_blocked_executions WHERE job_id = ?", id)
      Jobs.insert_execution("INSERT INTO spinrail_queue_ready_executions (job_id, queue_name, priority, created_at) VALUES (?, ?, ?, ?)",
                            id, queue_name, prio, "")
    end

    # Expired semaphores go, and keys with blocked jobs past their expiry get
    # another try: a job that died holding a slot doesn't block its key for good.
    def self.expire_concurrency
      now = Jobs.now
      db = Spinrail.prepare("DELETE FROM spinrail_queue_semaphores WHERE expires_at < ?", true)
      db.bind_str(1, now)
      db.step
      db.finalize
      db = Spinrail.prepare("SELECT DISTINCT concurrency_key FROM spinrail_queue_blocked_executions WHERE expires_at < ? LIMIT 100", true)
      db.bind_str(1, now)
      keys = [""]
      keys.clear
      keys << db.col_str(0) while db.step == 1
      db.finalize
      keys.each { |key| Spinrail.transaction { Jobs.unblock(key) } }
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
                            "SELECT s.job_id, s.queue_name, s.priority, ? FROM spinrail_queue_scheduled_executions s " \
                            "JOIN spinrail_queue_jobs j ON j.id = s.job_id WHERE s.scheduled_at <= ? AND j.concurrency_key = '' " \
                            "ON CONFLICT DO NOTHING", true)
      db.bind_str(1, now)
      db.bind_str(2, now)
      db.step
      db.finalize
      db = Spinrail.prepare("DELETE FROM spinrail_queue_scheduled_executions WHERE scheduled_at <= ? AND job_id IN " \
                            "(SELECT job_id FROM spinrail_queue_ready_executions)", true)
      db.bind_str(1, now)
      db.step
      db.finalize
      # Jobs with a concurrency key go one by one, through their semaphore.
      db = Spinrail.prepare("SELECT s.job_id, j.class_name, j.concurrency_key, s.queue_name, s.priority " \
                            "FROM spinrail_queue_scheduled_executions s JOIN spinrail_queue_jobs j ON j.id = s.job_id " \
                            "WHERE s.scheduled_at <= ? ORDER BY s.scheduled_at, s.priority, s.job_id LIMIT 100", true)
      db.bind_str(1, now)
      ids = [0]
      ids.clear
      rows = [""]
      rows.clear
      prios = [0]
      prios.clear
      while db.step == 1
        ids << db.col_int(0)
        rows << db.col_str(1)
        rows << db.col_str(2)
        rows << db.col_str(3)
        prios << db.col_int(4)
      end
      db.finalize
      ids.each_with_index do |id, i|
        Jobs.delete_where("DELETE FROM spinrail_queue_scheduled_executions WHERE job_id = ?", id)
        Jobs.make_ready(id, rows[i * 3], rows[i * 3 + 1], rows[i * 3 + 2], prios[i])
      end
      Spinrail.db.exec("COMMIT")
    end

    # "*" polls every queue by priority; otherwise queues in the order
    # given, "name*" matching a prefix.
    def self.poll_sql(queue)
      sql = "SELECT job_id FROM spinrail_queue_ready_executions WHERE queue_name NOT IN (SELECT queue_name FROM spinrail_queue_pauses)"
      if queue.end_with?("*") && queue != "*"
        sql += " AND queue_name LIKE '" + queue.delete_suffix("*").gsub("'", "''") + "%'"
      elsif queue != "*"
        sql += " AND queue_name = '" + queue.gsub("'", "''") + "'"
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
      db = Spinrail.prepare("SELECT class_name, arguments, queue_name, priority, executions, concurrency_key FROM spinrail_queue_jobs WHERE id = ?", true)
      db.bind_int(1, id)
      name = ""
      arguments = "[]"
      queue_name = ""
      prio = 0
      executions = 1
      key = ""
      if db.step == 1
        name = db.col_str(0)
        arguments = db.col_str(1)
        queue_name = db.col_str(2)
        prio = db.col_int(3)
        executions = db.col_int(4) + 1
        key = db.col_str(5)
      end
      db.finalize
      t0 = Spinrail.clock
      begin
        SpinrailJobs.dispatch(name, Jobs.decode(arguments))
        Jobs.finish(id, name, key)
        Spinrail.say("Performed " + name + " #" + id.to_s + " in " + format("%.1f", (Spinrail.clock - t0) * 1000.0) + "ms")
      rescue StandardError => e
        wait = SpinrailJobs.retry_wait(name, e, executions)
        if wait == DISCARD
          Jobs.finish(id, name, key)
          Spinrail.say("Discarded " + name + " #" + id.to_s + ": " + e.message)
        elsif wait == FAIL
          Jobs.fail(id, e.class.name + ": " + e.message, name, key)
          Spinrail.say("Failed " + name + " #" + id.to_s + ": " + e.message)
        else
          at = Spinrail.format_time(Time.now + wait)
          Spinrail.transaction do
            Jobs.finish(id, name, key)
            Jobs.insert(name, arguments, queue_name, prio, wait > 0 ? at : "", executions, key)
          end
          Spinrail.say("Failed " + name + " #" + id.to_s + ": " + e.message + " (retrying in " + wait.to_s + "s)")
        end
      end
      true
    end

    def self.finish(id, name, key)
      Spinrail.transaction do
        Jobs.release(id)
        Jobs.mark_finished(id)
        Jobs.signal(name, key)
      end
    end

    def self.mark_finished(id)
      db = Spinrail.prepare("UPDATE spinrail_queue_jobs SET finished_at = ?, updated_at = ? WHERE id = ?", true)
      now = Jobs.now
      db.bind_str(1, now)
      db.bind_str(2, now)
      db.bind_int(3, id)
      db.step
      db.finalize
    end

    def self.fail(id, error, name, key)
      Spinrail.transaction do
        Jobs.release(id)
        Jobs.signal(name, key)
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

    def self.heartbeat_interval = ENV.fetch("SPINRAIL_JOBS_HEARTBEAT_INTERVAL", "60").to_f

    def self.alive_threshold = ENV.fetch("SPINRAIL_JOBS_ALIVE_THRESHOLD", "300").to_i

    # TERM or INT: finish the jobs at hand, hand the rest back, and exit.
    STOP = [false]

    def self.trap_signals
      Signal.trap("TERM") { STOP[0] = true }
      Signal.trap("INT") { STOP[0] = true }
    end

    def self.register(threads)
      now = Jobs.now
      db = Spinrail.prepare("INSERT INTO spinrail_queue_processes (kind, name, pid, hostname, metadata, last_heartbeat_at, created_at) " \
                            "VALUES ('Worker', ?, ?, ?, ?, ?, ?)", true)
      db.bind_str(1, "worker-" + SecureRandom.hex(10))
      db.bind_int(2, Process.pid)
      db.bind_str(3, ENV.fetch("HOSTNAME", ""))
      db.bind_str(4, "{" + Tep::Json.encode_pair_str("queues", Jobs.queues.join(",")) + "," +
                     Tep::Json.encode_pair_int("thread_pool_size", threads) + "}")
      db.bind_str(5, now)
      db.bind_str(6, now)
      db.step
      db.finalize
      db.last_rowid
    end

    def self.heartbeat(process_id)
      db = Spinrail.prepare("UPDATE spinrail_queue_processes SET last_heartbeat_at = ? WHERE id = ?", true)
      db.bind_str(1, Jobs.now)
      db.bind_int(2, process_id)
      db.step
      db.finalize
    end

    # On a clean exit what the process had claimed goes back to ready.
    def self.deregister(process_id)
      Spinrail.transaction do
        db = Spinrail.prepare("INSERT INTO spinrail_queue_ready_executions (job_id, queue_name, priority, created_at) " \
                              "SELECT j.id, j.queue_name, j.priority, ? FROM spinrail_queue_jobs j " \
                              "JOIN spinrail_queue_claimed_executions c ON c.job_id = j.id WHERE c.process_id = ? ON CONFLICT DO NOTHING", true)
        db.bind_str(1, Jobs.now)
        db.bind_int(2, process_id)
        db.step
        db.finalize
        Jobs.delete_where("DELETE FROM spinrail_queue_claimed_executions WHERE process_id = ?", process_id)
        Jobs.delete_where("DELETE FROM spinrail_queue_processes WHERE id = ?", process_id)
      end
    end

    # Recurring tasks (config/recurring.yml, generated into SpinrailRecurring).
    # Every worker schedules them; the unique (task_key, run_at) index lets
    # one enqueue each run. A task first runs at its next slot after start.
    def self.recurring? = ENV.fetch("SPINRAIL_JOBS_SKIP_RECURRING", "") != "1"

    def self.recurring_slots
      t = Time.now
      SpinrailRecurring.keys.each_index.map { |i| SpinrailRecurring.slot(i, t) }
    end

    def self.schedule(last)
      t = Time.now
      SpinrailRecurring.keys.each_index do |i|
        env = SpinrailRecurring.envs[i]
        next unless env.empty? || env == Spinrail.env
        at = SpinrailRecurring.slot(i, t)
        next if at.empty? || at == last[i]
        last[i] = at
        SpinrailRecurring.fire(i, at)
      end
    end

    def self.minute_slot(t) = Spinrail.format_time(Time.at(t.to_i - t.sec))

    def self.interval_slot(t, seconds) = Spinrail.format_time(Time.at(t.to_i - t.to_i % seconds))

    def self.recur(key, at, name, args, queue, priority)
      return unless Spinrail.db.exec("BEGIN IMMEDIATE")
      db = Spinrail.prepare("INSERT INTO spinrail_queue_recurring_executions (job_id, task_key, run_at, created_at) VALUES (0, ?, ?, ?)", true)
      db.bind_str(1, key)
      db.bind_str(2, at)
      db.bind_str(3, Jobs.now)
      rc = db.step
      db.finalize
      if rc < 0
        Spinrail.db.exec("ROLLBACK")
        return
      end
      queue_name = queue.empty? ? SpinrailJobs.queue_for(name) : queue
      id = Jobs.insert(name, Jobs.encode(args), queue_name, priority < 0 ? SpinrailJobs.priority_for(name) : priority, "", 0,
                       SpinrailJobs.concurrency_key(name, args))
      db = Spinrail.prepare("UPDATE spinrail_queue_recurring_executions SET job_id = ? WHERE task_key = ? AND run_at = ?", true)
      db.bind_int(1, id)
      db.bind_str(2, key)
      db.bind_str(3, at)
      db.step
      db.finalize
      Spinrail.db.exec("COMMIT")
      Spinrail.say("Enqueued recurring task " + key + " as " + name + " #" + id.to_s)
    end

    def self.clear_finished_after = ENV.fetch("SPINRAIL_JOBS_CLEAR_FINISHED_AFTER", "86400").to_i

    # Finished jobs are kept a day (SPINRAIL_JOBS_CLEAR_FINISHED_AFTER), then
    # deleted 500 at a time so the write lock stays short.
    def self.clear_finished(all)
      cutoff = all ? "9999" : Spinrail.format_time(Time.now - Jobs.clear_finished_after)
      db = Spinrail.prepare("DELETE FROM spinrail_queue_jobs WHERE id IN (SELECT id FROM spinrail_queue_jobs " \
                            "WHERE finished_at != '' AND finished_at < ? ORDER BY id LIMIT 500)", true)
      db.bind_str(1, cutoff)
      db.step
      db.finalize
    end

    # Processes silent past the alive threshold died mid-job: as in Solid
    # Queue, their claimed jobs fail (they may have run partly) and the
    # process row goes. So do claims whose process row is already gone.
    def self.prune(process_id)
      cutoff = Spinrail.format_time(Time.now - Jobs.alive_threshold)
      Spinrail.transaction do
        db = Spinrail.prepare("INSERT INTO spinrail_queue_failed_executions (job_id, error, created_at) " \
                              "SELECT c.job_id, ?, ? FROM spinrail_queue_claimed_executions c " \
                              "LEFT JOIN spinrail_queue_processes p ON p.id = c.process_id " \
                              "WHERE c.process_id != ? AND (p.id IS NULL OR p.last_heartbeat_at < ?) ON CONFLICT DO NOTHING", true)
        db.bind_str(1, "ProcessPrunedError: the worker stopped sending heartbeats")
        db.bind_str(2, Jobs.now)
        db.bind_int(3, process_id)
        db.bind_str(4, cutoff)
        db.step
        db.finalize
        db = Spinrail.prepare("DELETE FROM spinrail_queue_claimed_executions WHERE job_id IN (SELECT job_id FROM spinrail_queue_failed_executions)", true)
        db.step
        db.finalize
        db = Spinrail.prepare("DELETE FROM spinrail_queue_processes WHERE id != ? AND last_heartbeat_at < ?", true)
        db.bind_int(1, process_id)
        db.bind_str(2, cutoff)
        db.step
        db.finalize
      end
    end

    def self.maintain(process_id)
      Jobs.heartbeat(process_id)
      Jobs.prune(process_id)
      Jobs.clear_finished(false)
      Jobs.expire_concurrency
    end

    def self.delete_where(sql, id)
      db = Spinrail.prepare(sql, true)
      db.bind_int(1, id)
      db.step
      db.finalize
    end

    # One worker's loop: dispatch due scheduled jobs at most once a second,
    # then perform ready ones, sleeping polling_interval when idle. With
    # beat, it also heartbeats and prunes; jobs on threads leave that to the
    # main thread, which a long job would otherwise hold up.
    def self.work(process_id, beat)
      queues = Jobs.queues
      interval = Jobs.polling_interval
      dispatched = 0.0
      beaten = Spinrail.clock
      last = Jobs.recurring_slots
      until STOP[0]
        if beat && Spinrail.clock - beaten >= Jobs.heartbeat_interval
          Jobs.maintain(process_id)
          beaten = Spinrail.clock
        end
        if Spinrail.clock - dispatched >= 1.0
          Jobs.schedule(last) if beat && Jobs.recurring?
          Jobs.dispatch_scheduled
          dispatched = Spinrail.clock
        end
        sleep interval unless Jobs.work_one(queues, process_id)
      end
    end

    def self.start
      Jobs.trap_signals
      id = Jobs.register(1)
      Jobs.prune(id)
      puts "spinrail: working jobs on " + Jobs.queues.join(",") + " (Ctrl+C to stop)"
      $stdout.flush
      Jobs.work(id, true)
      Jobs.stop(id)
    end

    def self.count(sql)
      db = Spinrail.prepare(sql, true)
      n = db.step == 1 ? db.col_int(0) : 0
      db.finalize
      n
    end

    def self.status
      [["ready", "spinrail_queue_ready_executions"], ["scheduled", "spinrail_queue_scheduled_executions"],
       ["claimed", "spinrail_queue_claimed_executions"], ["blocked", "spinrail_queue_blocked_executions"],
       ["failed", "spinrail_queue_failed_executions"],
       ["processes", "spinrail_queue_processes"]].map { |pair| pair[0] + "=" + Jobs.count("SELECT COUNT(*) FROM " + pair[1]).to_s }.join(" ") +
        " finished=" + Jobs.count("SELECT COUNT(*) FROM spinrail_queue_jobs WHERE finished_at != ''").to_s
    end

    def self.paused
      db = Spinrail.prepare("SELECT queue_name FROM spinrail_queue_pauses ORDER BY queue_name", true)
      out = [""]
      out.clear
      out << db.col_str(0) while db.step == 1
      db.finalize
      out
    end

    def self.failures
      db = Spinrail.prepare("SELECT j.id, j.class_name, j.queue_name, j.arguments, f.error, f.created_at FROM spinrail_queue_failed_executions f " \
                            "JOIN spinrail_queue_jobs j ON j.id = f.job_id ORDER BY j.id", true)
      out = [""]
      out.clear
      while db.step == 1
        out << db.col_int(0).to_s + " " + db.col_str(1) + " " + db.col_str(2) + " " + db.col_str(3) + " " + db.col_str(5) + "  " + db.col_str(4)
      end
      db.finalize
      out
    end

    # Pausing keeps a queue's jobs ready but unclaimed, as in Solid Queue.
    def self.pause(queue)
      db = Spinrail.prepare("INSERT INTO spinrail_queue_pauses (queue_name, created_at) VALUES (?, ?) ON CONFLICT DO NOTHING", true)
      db.bind_str(1, queue)
      db.bind_str(2, Jobs.now)
      db.step
      db.finalize
    end

    def self.resume(queue)
      db = Spinrail.prepare("DELETE FROM spinrail_queue_pauses WHERE queue_name = ?", true)
      db.bind_str(1, queue)
      db.step
      db.finalize
    end

    # A failed job (id 0: all of them) goes back to ready, the same job row.
    def self.retry_failed(id)
      Spinrail.transaction do
        db = Spinrail.prepare("INSERT INTO spinrail_queue_ready_executions (job_id, queue_name, priority, created_at) " \
                              "SELECT j.id, j.queue_name, j.priority, ? FROM spinrail_queue_jobs j " \
                              "JOIN spinrail_queue_failed_executions f ON f.job_id = j.id WHERE ? = 0 OR j.id = ? ON CONFLICT DO NOTHING", true)
        db.bind_str(1, Jobs.now)
        db.bind_int(2, id)
        db.bind_int(3, id)
        db.step
        db.finalize
        Jobs.delete_failed("DELETE FROM spinrail_queue_failed_executions WHERE ? = 0 OR job_id = ?", id)
      end
    end

    def self.discard_failed(id)
      Spinrail.transaction do
        Jobs.delete_failed("DELETE FROM spinrail_queue_jobs WHERE id IN (SELECT job_id FROM spinrail_queue_failed_executions WHERE ? = 0 OR job_id = ?)", id)
        Jobs.delete_failed("DELETE FROM spinrail_queue_failed_executions WHERE ? = 0 OR job_id = ?", id)
      end
    end

    def self.delete_failed(sql, id)
      db = Spinrail.prepare(sql, true)
      db.bind_int(1, id)
      db.bind_int(2, id)
      db.step
      db.finalize
    end

    # SPINRAIL_JOBS: "1" works jobs; "status", "failed", "pause QUEUE",
    # "resume QUEUE", "retry ID|all", "discard ID|all" and "clear" (finished
    # jobs) act on the queue and exit.
    def self.command(line)
      return if line.empty?
      Jobs.start if line == "1"
      words = line.split(" ")
      name = words[0]
      arg = words.length > 1 ? words[1] : ""
      id = arg == "all" ? 0 : arg.to_i
      if name == "status"
        puts Jobs.status
        paused = Jobs.paused
        puts "paused: " + paused.join(",") unless paused.empty?
      elsif name == "failed"
        Jobs.failures.each { |f| puts f }
      elsif (name == "pause" || name == "resume") && !arg.empty?
        name == "pause" ? Jobs.pause(arg) : Jobs.resume(arg)
        puts name + "d " + arg
      elsif (name == "retry" || name == "discard") && (arg == "all" || id > 0)
        name == "retry" ? Jobs.retry_failed(id) : Jobs.discard_failed(id)
        puts Jobs.status
      elsif name == "clear"
        Jobs.clear_finished(true) while Jobs.count("SELECT COUNT(*) FROM spinrail_queue_jobs WHERE finished_at != ''") > 0
        puts Jobs.status
      else
        $stderr.puts "spinrail: jobs takes status, failed, pause QUEUE, resume QUEUE, retry ID|all, discard ID|all or clear"
        exit(1)
      end
      exit(0)
    end

    def self.stop(process_id)
      Jobs.deregister(process_id)
      puts "spinrail: stopped working jobs"
      $stdout.flush
      exit(0)
    end
  end
end
