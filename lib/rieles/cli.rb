require "optparse"

module Rieles
  # `rieles <command>` run from an app's root (apps carry a bin/rieles
  # that does that). The toolchain lives in <repo>/vendor, see toolchain.mk.
  class CLI
    REPO = File.expand_path("../../..", __dir__)
    FRAMEWORK = File.expand_path("../..", __dir__)
    VENDOR = File.join(REPO, "vendor")
    TEP = File.join(VENDOR, "tep/bin/tep")

    COMMANDS = {
      "server" => "Build if needed and start the server (-p PORT, default 3000)",
      "build" => "Compile the app into a native binary (-o OUTPUT)",
      "routes" => "List the routes",
      "clean" => "Remove the binary, tmp/ and the development database",
      "setup" => "Clone and build spinel + tep into vendor/ (build and server do it on demand)"
    }.freeze
    ALIASES = { "s" => "server", "b" => "build", "r" => "routes" }.freeze

    def initialize(argv, app_dir = Dir.pwd)
      @argv = argv.dup
      @app = File.expand_path(app_dir)
    end

    def run
      command = ALIASES.fetch(@argv.first, @argv.first)
      @argv.shift
      case command
      when "server" then server
      when "build" then build(option("-o") || binary, force: true)
      when "routes" then routes
      when "clean" then clean
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
      build(binary) if stale?
      Dir.chdir(@app)
      puts "rieles: http://localhost:#{port} (Ctrl+C to stop)"
      $stdout.flush
      exec(binary, "-p", port)
    end

    def routes
      Build.new(@app).routes.routes.each do |r|
        target = r.controller ? "#{r.controller}##{r.action}" : Rieles.class_name(r.action, "Actions")
        puts format("%-7s %-22s %s", r.verb.to_s.upcase, r.path, target)
      end
    end

    def clean
      FileUtils.rm_rf([binary, File.join(@app, "tmp"), *Dir[File.join(@app, "db/*.sqlite3")]])
    end

    def setup
      system("make", "-s", "-C", REPO, "-f", "toolchain.mk", "setup") or abort "rieles: toolchain setup failed"
    end

    def build(output, force: false)
      return unless force || stale?
      setup unless File.executable?(File.join(VENDOR, "spinel/spinel")) && File.exist?(TEP)
      source = Build.new(@app).write(File.join(@app, "tmp/rieles"))
      env = {
        "SPINEL" => File.join(VENDOR, "spinel/spinel"),
        "SPINELKIT_DIR" => File.join(VENDOR, "spinelkit"),
        "TEP_SKIP_SPINEL_FRESH" => "1"
      }
      system(env, TEP, "build", source, "-o", output) or abort "rieles: build failed"
    end

    def stale?
      return true unless File.exist?(binary)
      built = File.mtime(binary)
      inputs = Dir[File.join(@app, "{app,config,db}/**/*")].reject { |f| f.end_with?(".sqlite3") } +
               Dir[File.join(FRAMEWORK, "{lib,runtime}/**/*.rb")]
      inputs.any? { |f| File.file?(f) && File.mtime(f) > built }
    end
  end
end
