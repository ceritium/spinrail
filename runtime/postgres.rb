# Compiled in when RIELES_DATABASE=postgres. Gives tep's PG battery the
# cursor-style interface the generated code uses with Tep::SQLite, and
# translates the few SQLite-isms rieles emits.
module Rieles
  class PgConnection
    PQTRANS_IDLE = 0

    def initialize
      @conn = PG::Connection.new("")
      @result = PG::Result.new(-1)
      @sql = ""
      @params = [""]
      @params.clear
      @executed = false
      @row = -1
      @last_id = 0
      @own_transaction = false
      @error = ""
    end

    def open(url)
      @conn = PG.connect(url)
      @conn.connected?
    end

    def close
      @conn.close
      0
    end

    # Rieles.transaction uses savepoints, which PostgreSQL only allows inside
    # a transaction block: open one around the outermost savepoint.
    def exec(sql)
      return true if sql.start_with?("PRAGMA")
      if sql.start_with?("SAVEPOINT") && @conn.transaction_status == PQTRANS_IDLE
        return false unless run("BEGIN")
        @own_transaction = true
      end
      ok = run(translate(sql))
      if sql.start_with?("RELEASE") && @own_transaction
        @own_transaction = false
        return run("COMMIT")
      end
      ok
    end

    def run(sql)
      @conn.exec(sql).ok?
    rescue StandardError
      false
    end

    def prepare(sql)
      @sql = translate(sql)
      @params = [""]
      @params.clear
      @executed = false
      @row = -1
      true
    end

    def prepare_cached(sql) = prepare(sql)

    def bind_str(index, value)
      @params << value while @params.length < index - 1
      if @params.length == index - 1
        @params << value
      else
        @params[index - 1] = value
      end
    end

    def bind_int(index, value) = bind_str(index, value.to_s)

    # Runs on the first call; then 1 per row and 0 at the end, -1 on error.
    def step
      unless @executed
        @executed = true
        insert = @sql.start_with?("INSERT INTO")
        sql = numbered(@sql) + (insert && !@sql.include?("RETURNING") ? " RETURNING *" : "")
        begin
          @result = @conn.exec_params(sql, @params)
        rescue StandardError => e
          @error = e.class.name + ": " + @conn.error_message
          return -1
        end
        unless @result.ok?
          @error = @result.error_message
          return -1
        end
        if insert
          @last_id = @result.ntuples > 0 && @result.fname(0) == "id" ? @result.getvalue(0, 0).to_i : 0
          return 0
        end
      end
      @row += 1
      @row < @result.ntuples ? 1 : 0
    end

    def col_str(i) = @result.getvalue(@row, i)

    # Booleans (x IS NULL) come back as t/f.
    def col_int(i)
      value = col_str(i)
      return 1 if value == "t"
      return 0 if value == "f"
      value.to_i
    end

    def last_error = @error

    def finalize = 0
    def last_rowid = @last_id

    def translate(sql)
      return table_info(sql) if sql.start_with?("PRAGMA table_info(")
      out = sql.sub("INTEGER PRIMARY KEY", "BIGSERIAL PRIMARY KEY").gsub(" REAL", " DOUBLE PRECISION")
               .gsub("char(1)", "chr(1)").gsub(" LIMIT -1", " LIMIT ALL").sub("BEGIN IMMEDIATE", "BEGIN")
      if out.start_with?("INSERT OR REPLACE INTO rieles_cache")
        out = out.sub("INSERT OR REPLACE INTO", "INSERT INTO") +
              " ON CONFLICT (key) DO UPDATE SET value = EXCLUDED.value, expires_at = EXCLUDED.expires_at"
      end
      out
    end

    def table_info(sql)
      table = sql.delete_prefix("PRAGMA table_info(").delete_suffix(")")
      "SELECT 0, column_name FROM information_schema.columns WHERE table_schema = current_schema() AND table_name = '" +
        table + "'"
    end

    # ? -> $1, $2, ... outside quoted literals.
    def numbered(sql)
      out = +""
      n = 0
      quoted = false
      sql.each_char do |c|
        quoted = !quoted if c == "'"
        if c == "?" && !quoted
          n += 1
          out << "$" + n.to_s
        else
          out << c
        end
      end
      out
    end
  end
end
