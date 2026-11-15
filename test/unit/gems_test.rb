require_relative "helper"
require "tmpdir"

class GemsTest < Minitest::Test
  def test_bundled_files_come_before_the_files_that_require_them
    Dir.mktmpdir do |dir|
      files = {
        "greeter/lib/greeter.rb" => "module Greeter\n  require \"greeter/hello\"\n  require \"forwardable\"\n  require \"pngish\"\nend\n",
        "greeter/lib/greeter/hello.rb" => "require_relative \"words\"\nclass Greeter::Hello\n  def png = require \"pngish\"\nend\n",
        "greeter/lib/greeter/words.rb" => "module Greeter\n  WORDS = [\"hi\"]\nend\n",
        "pngish/lib/pngish.rb" => "raise \"left out\"\n"
      }
      files.each do |name, src|
        FileUtils.mkdir_p(File.dirname(File.join(dir, name)))
        File.write(File.join(dir, name), src)
      end
      gems = Spinrail::Gems.new([["greeter"]], ["#{dir}/greeter/lib", "#{dir}/pngish/lib"], excluded: ["pngish"])
      source = gems.source

      assert source.start_with?("require \"forwardable\"\n")
      order = %w[words.rb hello.rb greeter.rb].map { |f| source.index("greeter/#{f}") || source.index("lib/#{f}") }
      assert_equal order.sort, order
      assert_includes source, "def png = require \"pngish\""
      refute_includes source, "left out"
      refute_match(/^\s*require(_relative)? "greeter/, source)
    end
  end

  def test_a_require_nothing_provides_fails_the_build
    error = assert_raises(Spinrail::CompileError) { Spinrail::Gems.new([["missing"]], []).source }
    assert_includes error.message, "missing"
  end

  def test_no_gemfile_no_gems
    Dir.mktmpdir { |dir| assert_equal "", Spinrail::Gems.for_app(dir).source }
  end
end
