require "optparse"
require "open3"

module Rieles
  # `rieles <command>` run from an app's root (apps carry a bin/rieles
  # that does that). The toolchain lives in <repo>/vendor, see toolchain.mk.
  class CLI
    REPO = File.expand_path("../../..", __dir__)
    FRAMEWORK = File.expand_path("../..", __dir__)
    VENDOR = File.join(REPO, "vendor")
    TEP = File.join(VENDOR, "tep/bin/tep")

    COMMANDS = {
      "new" => "Create an app: rieles new PATH",
      "generate" => "model|controller|scaffold NAME [field:type ...] (alias g)",
      "server" => "Build if needed, start the server and rebuild on change (-p PORT, -w WORKERS, --no-reload)",
      "build" => "Compile the app into a native binary (-o OUTPUT)",
      "routes" => "List the routes",
      "test" => "Build if needed and run test/**/*_test.rb (FILES, minitest options)",
      "db:migrate" => "Apply db/migrate and rewrite db/schema.rb from it",
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
      when "test" then test
      when "clean" then clean
      when "db:migrate" then migrate
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
      inputs = Dir[File.join(@app, "{app,config,db}/**/*")].reject { |f| f.end_with?(".sqlite3") } +
               Dir[File.join(FRAMEWORK, "{lib,runtime}/**/*.rb")]
      inputs.select { |f| File.file?(f) }.to_h { |f| [f, File.mtime(f)] }
    end

    def routes
      all = Build.new(@app).routes.routes
      width = all.map { |r| r.path.size }.max.to_i
      all.each do |r|
        target = r.controller ? "#{r.controller}##{r.action}" : Rieles.class_name(r.action, "Actions")
        puts format("%-7s %-#{width}s  %s", r.verb.to_s.upcase, r.path, target)
      end
    end

    def test
      Dir.chdir(@app)
      files, options = @argv.partition { |a| a.end_with?(".rb") || File.directory?(a) }
      files = ["test"] if files.empty?
      files = files.flat_map { |f| f.end_with?(".rb") ? [f] : Dir[File.join(f, "**/*_test.rb")].sort }
      abort "rieles: no tests in test/" if files.empty?
      build(binary) if stale?
      FileUtils.mkdir_p(File.join(@app, "log"))
      File.write(File.join(@app, "log/test.log"), "")
      env = { "RIELES_APP" => @app, "RIELES_BINARY" => binary }
      loader = "files = ARGV.shift(#{files.size}); files.each { |f| require File.expand_path(f) }"
      $stdout.flush
      exec(env, RbConfig.ruby, "-I", File.join(FRAMEWORK, "lib"), "-r", "rieles/test", "-e", loader, *files, *options)
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

    def seed
      abort "rieles: no db/seeds.rb" unless File.exist?(File.join(@app, "db/seeds.rb"))
      build(binary) if stale?
      Dir.chdir(@app)
      system({ "RIELES_SEED" => "1" }, binary) or abort "rieles: seeding failed"
    end

    def reset_db
      database = ENV.fetch("DATABASE_PATH", File.join(@app, "db/development.sqlite3"))
      FileUtils.rm_f(database)
      puts "rieles: deleted #{database.delete_prefix("#{@app}/")}"
      seed if File.exist?(File.join(@app, "db/seeds.rb"))
    end

    def clean
      FileUtils.rm_rf([binary, File.join(@app, "tmp"), File.join(@app, "log"), *Dir[File.join(@app, "db/*.sqlite3")]])
    end

    def setup
      system("make", "-s", "-C", REPO, "-f", "toolchain.mk", "setup") or abort "rieles: toolchain setup failed"
    end

    def build(output, force: false)
      return unless force || stale?
      compile(output) or abort "rieles: build failed (generated source: tmp/rieles/app.rb)"
    end

    def compile(output)
      setup unless File.executable?(File.join(VENDOR, "spinel/spinel")) && File.exist?(TEP)
      source = Build.new(@app).write(File.join(@app, "tmp/rieles"))
      env = {
        "SPINEL" => File.join(VENDOR, "spinel/spinel"),
        "SPINELKIT_DIR" => File.join(VENDOR, "spinelkit"),
        "TEP_SKIP_SPINEL_FRESH" => "1"
      }
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
      warnings = log.lines.select { |l| l.match?(/warning|error/i) && KNOWN_WARNINGS.none? { |k| l.include?(k) } }
      warn warnings.join unless warnings.empty?
      true
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

    def stale?
      return true unless File.exist?(binary)
      built = File.mtime(binary)
      input_mtimes.values.any? { |t| t > built }
    end
  end
end
