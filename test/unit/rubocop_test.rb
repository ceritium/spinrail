require_relative "helper"
require "json"
require "open3"

# rubocop runs in its own process: rubocop-ast pins an older prism than spinrail loads.
class RubocopTest < CompilerTest
  LIB = File.expand_path("../../lib", __dir__)

  def setup
    skip "rubocop is not installed" if Gem::Specification.find_all_by_name("rubocop").empty?
  end

  def offenses(source)
    dir = app(".rubocop.yml" => "require:\n  - spinrail/rubocop\nAllCops:\n  TargetRubyVersion: 3.4\n", "app/x.rb" => source)
    out, = Open3.capture2(RbConfig.ruby, "-I", LIB, "-S", "rubocop", "--only", "Spinel", "--format", "json", chdir: dir)
    JSON.parse(out)["files"].flat_map { |f| f["offenses"].map { |o| o["cop_name"] } }
  end

  def test_flags_what_spinel_refuses
    source = <<~RUBY
      def method_missing(name) = super
      eval("1")
      instance_eval("@a")
      send(name)
      define_method("x_\#{name}") { 1 }
      Object.const_get(name)
      ObjectSpace.each_object(String) { 1 }
      binding
    RUBY
    assert_equal %w[Spinel/MethodMissing Spinel/Eval Spinel/Eval Spinel/DynamicName Spinel/DynamicName
                    Spinel/DynamicName Spinel/Reflection Spinel/Reflection], offenses(source)
  end

  def test_leaves_what_compiles
    source = <<~RUBY
      request.method
      send(:save, 1)
      define_method(:x) { 1 }
      instance_eval { 1 }
      instance_variable_get(:@a)
      binding.local_variable_get(:a)
      ObjectSpace.define_finalizer(self, proc {})
    RUBY
    assert_empty offenses(source)
  end
end
