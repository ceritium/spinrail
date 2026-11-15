require "open3"
require "rbconfig"

module Spinrail
  # The app's bundled gems, compiled into the binary the way Bundler.require
  # loads them: each default-group gem is required, and every file it requires
  # from the bundle is spliced in ahead of the file that requires it (spinel
  # has no load path). A gem marked `require: false` stays out, even when
  # another gem requires it; requires nothing in the bundle provides are kept
  # for spinel (its bundled packages) or tep to resolve.
  class Gems
    QUERY = <<~'RUBY'.freeze
      require "bundler/setup"
      require "json"
      definition = Bundler.definition
      deps = definition.dependencies.select { |d| d.groups.include?(:default) && d.name != "spinrail" }
      excluded = definition.dependencies.select { |d| d.autorequire == [] || !d.groups.include?(:default) }.map(&:name)
      paths = definition.specs_for([:default]).reject { |s| s.name == "spinrail" || excluded.include?(s.name) }
      puts JSON.generate(
        "requires" => deps.reject { |d| d.autorequire == [] }.map { |d| d.autorequire || [d.name, d.name.tr("-", "/")] },
        "load_path" => paths.flat_map(&:full_require_paths),
        "excluded" => excluded
      )
    RUBY

    def self.for_app(app)
      gemfile = File.join(app, "Gemfile")
      return new([], []) unless File.exist?(gemfile) && File.exist?("#{gemfile}.lock")

      env = { "BUNDLE_GEMFILE" => gemfile, "RUBYOPT" => nil, "RUBYLIB" => nil }
      run = -> { Open3.capture2e(env, RbConfig.ruby, "-e", QUERY, chdir: app) }
      out, status = defined?(Bundler) ? Bundler.with_unbundled_env(&run) : run.call
      raise CompileError, "reading the bundle failed:\n#{out}" unless status.success?

      bundle = JSON.parse(out.lines.last)
      new(bundle["requires"], bundle["load_path"], excluded: bundle["excluded"])
    end

    # requires: one list of features per gem; the first one found loads it.
    def initialize(requires, load_path, excluded: [])
      @requires = requires
      @load_path = load_path
      @excluded = excluded
    end

    def source
      @seen = {}
      @out = []
      @kept = []
      @requires.each do |features|
        file = features.lazy.filter_map { |f| find(f) }.first
        raise CompileError, "no file in the bundle for require #{features.first.inspect}" unless file

        visit(file)
      end
      return "" if @out.empty?

      [*@kept.uniq.map { |f| "require #{f.inspect}" }, *@out].join("\n") + "\n"
    end

    private

    def find(feature)
      @load_path.map { |dir| File.join(dir, "#{feature.delete_suffix('.rb')}.rb") }.find { |f| File.file?(f) }
    end

    def visit(file)
      return if @seen[file]

      @seen[file] = true
      src = File.read(file)
      calls = requires_in(Prism.parse(src).value)
      calls.each do |call, kind, feature|
        if kind == :relative
          visit(File.expand_path("#{feature.delete_suffix('.rb')}.rb", File.dirname(file)))
        elsif @excluded.include?(feature.split("/").first)
          next
        elsif (found = find(feature))
          visit(found)
        else
          @kept << feature
        end
      end
      # Same length in bytes, so later offsets stay put.
      calls.sort_by { |call, *| -call.location.start_offset }.each do |call, *|
        loc = call.location
        src = src.byteslice(0, loc.start_offset) + "nil".ljust(loc.length) + src.byteslice(loc.end_offset..)
      end
      @out << "#{Build::SOURCE_MARK}#{file}\n#{src}"
    end

    # Requires that run when the file loads, not those inside methods or blocks.
    def requires_in(node, found = [])
      case node
      when Prism::DefNode, Prism::BlockNode, Prism::LambdaNode then return found
      when Prism::CallNode
        arg = node.arguments&.arguments&.first
        if node.receiver.nil? && %i[require require_relative].include?(node.name) && arg.is_a?(Prism::StringNode)
          found << [node, node.name == :require ? :require : :relative, arg.unescaped]
          return found
        end
      end
      node.compact_child_nodes.each { |child| requires_in(child, found) }
      found
    end
  end
end
