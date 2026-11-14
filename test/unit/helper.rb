require "minitest/autorun"
require "tmpdir"
require_relative "../../lib/rieles"

class CompilerTest < Minitest::Test
  # Writes files into a throwaway app and returns its path.
  def app(files)
    dir = Dir.mktmpdir("rieles-unit")
    files.each do |name, body|
      file = File.join(dir, name)
      FileUtils.mkdir_p(File.dirname(file))
      File.write(file, body)
    end
    @dirs = (@dirs || []) << dir
    dir
  end

  def teardown
    (@dirs || []).each { |d| FileUtils.rm_rf(d) }
  end

  def lower(source, view: false, controller: true)
    ctx = Rieles::Build::Context.new(nil, "posts", view: view, controller: controller)
    Rieles::Lowering.lower(source, "test.rb", ctx)
  end

  def minimal_app(extra = {})
    app({
      "config/routes.rb" => "Rieles.routes.draw do\nend\n",
      "db/schema.rb" => "Rieles::Schema.define do\nend\n"
    }.merge(extra))
  end
end
