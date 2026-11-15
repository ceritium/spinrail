module Spinrail
  # Reads config/importmap.rb into module name => logical asset name.
  class Importmap
    def initialize(app, asset_files)
      @app = app
      @logical = asset_files.to_h { |name, file| [file, name] }
      @pins = {}
    end

    def load(file)
      instance_eval(File.read(file), file)
      @pins
    end

    def pin(name, to: nil, preload: true)
      @pins[name] = to || "#{name}.js"
    end

    def pin_all_from(dir, under: nil, to: nil, preload: true)
      root = File.expand_path(dir, @app)
      Dir["#{root}/**/*.js"].sort.each do |file|
        module_path = file.delete_prefix("#{root}/").delete_suffix(".js")
        module_path = module_path == "index" ? nil : module_path.delete_suffix("/index")
        name = [under, module_path].compact.join("/")
        name = module_path if name.empty?
        @pins[name] = @logical.fetch(file) { raise CompileError, "config/importmap.rb: #{dir} is outside the asset paths" }
      end
    end
  end
end
