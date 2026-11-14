require "optparse"
require "open3"
require "tmpdir"

module Rieles
  # `rieles <command>` run from an app's root (apps carry a bin/rieles
  # that does that). The toolchain lives in <repo>/vendor, see toolchain.mk.
  class CLI
    TOOLCHAIN = File.expand_path("../../toolchain.mk", __dir__)
    # In a checkout, <repo>/vendor; as a gem, RIELES_VENDOR or ~/.cache/rieles.
    CHECKOUT_VENDOR = File.expand_path("../../../vendor", __dir__)
    FRAMEWORK = File.expand_path("../..", __dir__)
    VENDOR = ENV.fetch("RIELES_VENDOR") do
      File.exist?(File.expand_path("../../../.git", __dir__)) ? CHECKOUT_VENDOR : File.join(Dir.home, ".cache/rieles/vendor")
    end
    TEP = File.join(VENDOR, "tep/bin/tep")

    COMMANDS = {
      "new" => "Create an app: rieles new PATH",
      "generate" => "model|controller|scaffold NAME [field:type ...] (alias g)",
      "server" => "Build if needed, start the server and rebuild on change (-p PORT, -w WORKERS, --no-reload)",
      "build" => "Compile the app into a native binary (-o OUTPUT)",
      "routes" => "List the routes",
      "check" => "Run the build's static checks without compiling",
      "test" => "Build if needed and run test/**/*_test.rb (FILES, minitest options)",
      "jobs" => "Work background jobs (app/jobs) until Ctrl+C (-c THREADS)",
      "runner" => "Compile and run a script against the app: runner FILE or runner -e CODE",
      "db:migrate" => "Apply db/migrate and rewrite db/schema.rb from it",
      "db:rollback" => "Undo the latest applied migration",
      "db:seed" => "Run db/seeds.rb against the database",
      "db:reset" => "Delete the development database and seed it again",
      "clean" => "Remove the binary, tmp/, log/ and the development database",
      "setup" => "Clone and build spinel + tep into vendor/ (build and server do it on demand)"
    }.freeze
    ALIASES = { "s" => "server", "b" => "build", "r" => "routes", "t" => "test", "g" => "generate" }.freeze

    def initialize(argv, app_dir = Dir.pwd)
      @argv = argv.dup
      @app = File.expand_path(app_dir)
    end

    def run
      command = ALIASES.fetch(@argv.first, @argv.first)
      @argv.shift
      case command
      when "new" then Generators.new(File.expand_path(@argv.first || abort("rieles: new PATH"))).new_app
      when "generate" then Generators.new(@app).generate(@argv[0], @argv[1], @argv[2..] || [])
      when "server" then server
      when "build" then build(option("-o") || binary, force: true)
      when "routes" then routes
      when "check" then check
      when "test" then test
      when "clean" then clean
      when "jobs" then jobs
      when "runner" then runner
      when "db:migrate" then migrate
      when "db:rollback" then rollback
      when "db:seed" then seed
      when "db:reset" then reset_db
      when "setup" then setup
      else help(command)
      end
    rescue CompileError => e
      abort "rieles: #{e.message}"
    end

    private

    def binary = File.join(@app, File.basename(@app))

    def option(flag)
      i = @argv.index(flag)
      i ? @argv.slice!(i, 2).last : nil
    end

    def help(command)
      warn "rieles: unknown command #{command}" if command && !%w[help -h --help].include?(command)
      puts "Usage: rieles COMMAND\n\n"
      COMMANDS.each { |name, desc| puts format("  %-8s %s", name, desc) }
      exit(command.nil? || %w[help -h --help].include?(command) ? 0 : 1)
    end

    def server
      port = option("-p") || "3000"
      workers = option("-w")
      reload = !@argv.delete("--no-reload") && ENV.fetch("RIELES_ENV", "development") == "development"
      build(binary) if stale?
      Dir.chdir(@app)
      puts "rieles: http://localhost:#{port} (Ctrl+C to stop)"
      $stdout.flush
      exec(binary, "-p", port, *(workers ? ["-w", workers] : [])) unless reload
      watch(port)
    end

    # Rebuilds into a side file on change and swaps it in once it compiled,
    # so a broken edit leaves the running server alone.
    def watch(port)
      pid = start_server(port)
      trap("INT") do
        stop_server(pid)
        exit
      end
      seen = input_mtimes
      loop do
        sleep 0.5
        now = input_mtimes
        next if now == seen
        seen = now
        next_binary = "#{binary}.next"
        begin
          next unless compile(next_binary)
        rescue CompileError => e
          warn "rieles: #{e.message}"
          next
        end
        stop_server(pid)
        File.rename(next_binary, binary)
        pid = start_server(port)
      end
    end

    def start_server(port)
      10.times do
        pid = Process.spawn(binary, "-p", port)
        sleep 0.2
        return pid unless Process.wait(pid, Process::WNOHANG)
        sleep 0.3 # the old process may still hold the port
      end
      abort "rieles: the server didn't start"
    end

    def stop_server(pid)
      Process.kill("INT", pid)
      Process.wait(pid)
    rescue Errno::ESRCH, Errno::ECHILD
      nil
    end

    def input_mtimes
      inputs = Dir[File.join(@app, "{app,config,db}/**/*")].reject { |f| f.match?(/\.sqlite3(-wal|-shm|-journal)?\z/) } +
               Dir[File.join(FRAMEWORK, "{lib,runtime}/**/*.rb")] +
               Dir[File.join(VENDOR, "tep/{tep.rb,tep/**/*.{rb,c},native/**/*.c}")]
      inputs.select { |f| File.file?(f) }.to_h { |f| [f, File.mtime(f)] }
    end

    def check
      build = Build.new(@app)
      source = build.send(:generate)
      result = Prism.parse(source)
      abort "rieles: generated code doesn't parse: #{result.errors.first.message}" if result.failure?
      build.warnings.uniq.each { |w| warn "warning: #{w}" }
      puts "rieles: ok (#{build.routes.routes.size} routes, #{build.model_names.size} models)"
    end

    def routes
      all = Build.new(@app).routes.routes
      width = all.map { |r| r.path.size }.max.to_i
      all.each do |r|
        target = r.controller ? "#{r.controller}##{r.action}" : Rieles.class_name(r.action, "Actions")
        puts format("%-7s %-#{width}s  %s", r.verb.to_s.upcase, r.path, target)
      end
    end

    # test/models runs inside a test build of the binary; everything else
    # runs in CRuby against the app binary over HTTP.
    def test
      Dir.chdir(@app)
      files, options = @argv.partition { |a| a.end_with?(".rb") || File.directory?(a) }
      files = ["test"] if files.empty?
      files = files.flat_map { |f| f.end_with?(".rb") ? [f] : Dir[File.join(f, "**/*_test.rb")].sort }
      abort "rieles: no tests in test/" if files.empty?
      model_files, request_files = files.partition { |f| f.start_with?("test/models/") }
      FileUtils.mkdir_p(File.join(@app, "log"))
      File.write(File.join(@app, "log/test.log"), "")
      ok = model_files.empty? || model_tests(option_value(options, "-n"))
      return exit(ok ? 0 : 1) if request_files.empty?
      build(binary) if stale?
      env = { "RIELES_APP" => @app, "RIELES_BINARY" => binary }
      loader = "files = ARGV.shift(#{request_files.size}); files.each { |f| require File.expand_path(f) }"
      $stdout.flush
      system(env, RbConfig.ruby, "-I", File.join(FRAMEWORK, "lib"), "-r", "rieles/test", "-e", loader, *request_files, *options)
      exit(ok && $?.success? ? 0 : 1)
    end

    def option_value(options, flag)
      i = options.index(flag)
      i ? options[i + 1].to_s.delete_prefix("/").delete_suffix("/") : ""
    end

    def model_tests(filter)
      test_binary = File.join(@app, "tmp", "#{File.basename(@app)}-test")
      newest = (input_mtimes.values + Dir[File.join(@app, "test/**/*")].map { |f| File.mtime(f) }).max
      compile(test_binary, tests: true) or abort "rieles: build failed" if !File.exist?(test_binary) || newest > File.mtime(test_binary)
      Dir.mktmpdir("rieles-models") do |dir|
        env = { "DATABASE_PATH" => File.join(dir, "test.sqlite3"), "RIELES_ENV" => "test", "RIELES_RUN_TESTS" => "1",
                "RIELES_LOG_FILE" => File.join(@app, "log/test.log"), "RIELES_TEST_NAME" => filter }
        if ENV.fetch("RIELES_DATABASE", "sqlite") == "postgres"
          pg_database = "rieles_models_#{Process.pid}"
          system("createdb", pg_database, exception: true)
          env["DATABASE_URL"] = "postgres:///#{pg_database}"
        end
        require_relative "fixtures"
        sql = Fixtures.load(@app, ["all"])
        unless sql.empty?
          File.write(File.join(dir, "fixtures.sql"), sql)
          env["RIELES_BOOT_SQL"] = File.join(dir, "fixtures.sql")
        end
        puts "rieles: model tests"
        $stdout.flush
        system(env, test_binary)
      ensure
        system("dropdb", "--if-exists", pg_database) if pg_database
      end
    end

    def runner
      code = option("-e")
      file = @argv.shift unless code
      abort "rieles: runner FILE or runner -e 'puts Post.count'" unless code || file
      code ||= File.read(file)
      output = File.join(@app, "tmp", "#{File.basename(@app)}-runner")
      setup unless File.executable?(File.join(VENDOR, "spinel/spinel")) && File.exist?(TEP)
      compile(output, script: code) or abort "rieles: build failed"
      Dir.chdir(@app)
      $stdout.flush
      exec({ "RIELES_LOG_LEVEL" => ENV.fetch("RIELES_LOG_LEVEL", "error") }, output)
    end

    # -c N > 1 works N jobs at once on spinel threads, in a binary of its
    # own so the server keeps the single-threaded runtime.
    def jobs
      threads = option("-c").to_i
      if threads > 1
        output = File.join(@app, "tmp", "#{File.basename(@app)}-jobs")
        compile(output, threads: true) or abort "rieles: build failed" if !File.exist?(output) || input_mtimes.values.max > File.mtime(output)
        Dir.chdir(@app)
        $stdout.flush
        exec({ "RIELES_JOB_THREADS" => threads.to_s }, output)
      end
      build(binary) if stale?
      Dir.chdir(@app)
      $stdout.flush
      exec({ "RIELES_JOBS" => "1" }, binary)
    end

    def migrate
      migrations = Migrations.new(File.join(@app, "db/migrate"))
      abort "rieles: no migrations in db/migrate" unless migrations.any?
      schema = File.join(@app, "db/schema.rb")
      unless File.exist?(schema) && File.read(schema) == migrations.schema_rb
        File.write(schema, migrations.schema_rb)
        puts "rieles: wrote db/schema.rb"
      end
      build(binary) if stale?
      Dir.chdir(@app)
      system({ "RIELES_MIGRATE" => "1" }, binary) or abort "rieles: migrating failed"
    end

    def rollback
      abort "rieles: no migrations in db/migrate" unless Migrations.new(File.join(@app, "db/migrate")).any?
      build(binary) if stale?
      Dir.chdir(@app)
      system({ "RIELES_ROLLBACK" => "1" }, binary) or abort "rieles: rollback failed"
    end

    def seed
      abort "rieles: no db/seeds.rb" unless File.exist?(File.join(@app, "db/seeds.rb"))
      build(binary) if stale?
      Dir.chdir(@app)
      system({ "RIELES_SEED" => "1" }, binary) or abort "rieles: seeding failed"
    end

    def reset_db
      database = ENV.fetch("DATABASE_PATH", File.join(@app, "db/development.sqlite3"))
      FileUtils.rm_f([database, "#{database}-wal", "#{database}-shm"])
      puts "rieles: deleted #{database.delete_prefix("#{@app}/")}"
      seed if File.exist?(File.join(@app, "db/seeds.rb"))
    end

    def clean
      FileUtils.rm_rf([binary, File.join(@app, "tmp"), File.join(@app, "log"), *Dir[File.join(@app, "db/*.sqlite3*")]])
    end

    def setup
      FileUtils.mkdir_p(VENDOR)
      system("make", "-s", "-f", TOOLCHAIN, "VENDOR=#{VENDOR}", "setup") or abort "rieles: toolchain setup failed"
    end

    def build(output, force: false)
      return unless force || stale?
      compile(output) or abort "rieles: build failed (generated source: tmp/rieles/app.rb)"
    end

    def compile(output, tests: false, script: nil, threads: false)
      setup unless File.executable?(File.join(VENDOR, "spinel/spinel")) && File.exist?(TEP)
      build = Build.new(@app, tests: tests, script: script, threads: threads)
      dir = if tests then "tmp/rieles-test"
            elsif script then "tmp/rieles-runner"
            elsif threads then "tmp/rieles-jobs"
            else "tmp/rieles"
            end
      source = build.write(File.join(@app, dir))
      build.warnings.uniq.each { |w| warn "warning: #{w}" }
      env = {
        "SPINEL" => File.join(VENDOR, "spinel/spinel"),
        "SPINELKIT_DIR" => File.join(VENDOR, "spinelkit"),
        "TEP_SKIP_SPINEL_FRESH" => "1"
      }
      env.merge!(postgres_env) if ENV.fetch("RIELES_DATABASE", "sqlite") == "postgres"
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      $stdout.print "rieles: compiling #{File.basename(@app)}... "
      $stdout.flush
      log, status = Open3.capture2e(env, TEP, "build", source, "-o", output)
      unless status.success?
        puts "failed"
        $stdout.flush
        warn log
        warn source_hints(log, source)
        return false
      end
      puts format("done in %.1fs", Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
      File.write(flavor_file, flavor) if output == binary
      warnings = log.lines.select { |l| l.match?(/warning|error/i) && KNOWN_WARNINGS.none? { |k| l.include?(k) } }
      warn warnings.join unless warnings.empty?
      true
    end

    # tep's PG battery: its C shim, built once next to its source, and
    # libpq's flags from pg_config (Homebrew's libpq isn't on the default path).
    def postgres_env
      pg_config = ENV.fetch("PG_CONFIG", "pg_config")
      include_dir = `#{pg_config} --includedir`.strip
      lib_dir = `#{pg_config} --libdir`.strip
      abort "rieles: pg_config not found; install libpq or set PG_CONFIG" if include_dir.empty?
      shim = File.join(VENDOR, "tep/native/pg/tep_pg.o")
      unless File.exist?(shim)
        system("cc", "-O2", "-I#{include_dir}", "-c", shim.sub(/\.o\z/, ".c"), "-o", shim) or abort "rieles: building tep_pg.o failed"
      end
      { "TEP_PG_O" => shim, "TEP_PG_CFLAGS" => "-I#{include_dir}", "TEP_PG_LIBS" => "-L#{lib_dir} -lpq",
        "LIBRARY_PATH" => [lib_dir, ENV["LIBRARY_PATH"]].compact.join(":") }
    end

    # Harmless and not actionable by apps (see the build notes in README).
    KNOWN_WARNINGS = ["Router @routes: Array[Route] stays a boxed array", "ignoring duplicate libraries", "linker' input unused"].freeze

    # tep drops comments, so the failing line of its .tep.rb is looked up
    # by text in our app.rb, whose section marks name the app file.
    def source_hints(log, source)
      ours = File.readlines(source)
      hints = log.scan(/(\S+\.tep\.rb):(\d+)/).uniq.filter_map do |file, line|
        next unless File.exist?(file)
        text = File.readlines(file)[line.to_i - 1]&.strip
        next if text.nil? || text.empty?
        text = text.sub(/\s*# L\d+\z/, "")
        n = ours.index { |l| l.sub(/\s*# L\d+\s*\z/, "").strip == text } or next
        mark = n.downto(0).find { |i| ours[i].strip.start_with?(Build::SOURCE_MARK.strip) } or next
        origin = ours[mark].strip.delete_prefix(Build::SOURCE_MARK.strip).strip
        if origin.start_with?("erb ")
          erb_line = ours[n][/# L(\d+)\s*\z/, 1]
          next "  #{origin.delete_prefix('erb ')}#{erb_line ? ":#{erb_line}" : ''}: #{text.sub(/\s*# L\d+\z/, '')}"
        end
        next "  in code generated from #{origin.delete_prefix('generated ')}: #{text}" if origin.start_with?("generated ")
        "  #{origin}:#{n - mark}: #{text}"
      end
      hints.empty? ? "" : "rieles: the error is near\n#{hints.uniq.join("\n")}"
    end

    # The database adapter is chosen at build time, so switching it rebuilds.
    def flavor_file = File.join(@app, "tmp/.database")
    def flavor = ENV.fetch("RIELES_DATABASE", "sqlite")

    def stale?
      return true unless File.exist?(binary)
      return true unless File.exist?(flavor_file) && File.read(flavor_file) == flavor
      built = File.mtime(binary)
      input_mtimes.values.any? { |t| t > built }
    end
  end
end
