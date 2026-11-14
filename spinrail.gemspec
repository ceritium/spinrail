Gem::Specification.new do |spec|
  spec.name = "spinrail"
  spec.version = "0.1.0"
  spec.summary = "Rails-shaped apps compiled to native binaries with tep and spinel"
  spec.authors = ["José Galisteo"]
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.4"
  spec.files = Dir["lib/**/*.rb", "runtime/**/*.rb", "exe/*", "toolchain.mk", "README.md"]
  spec.bindir = "exe"
  spec.executables = ["spinrail"]
  spec.add_dependency "prism"
  spec.add_dependency "minitest"
  spec.add_dependency "base64"
  spec.add_development_dependency "rubocop"
end
