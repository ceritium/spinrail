require "rake/testtask"

Rake::TestTask.new(:unit) do |t|
  t.test_files = FileList["test/unit/*_test.rb"]
  t.warning = false
end

desc "Request tests of the dummy app and the guestbook (builds both)"
task :apps do
  %w[test/dummy examples/guestbook].each do |dir|
    sh File.join(dir, "bin/spinrail"), "test"
  end
end

# Repo style plus the Spinel cops on what spinel compiles (see .rubocop.yml).
desc "RuboCop (config in .rubocop.yml)"
task :lint do
  sh "bundle", "exec", "rubocop"
end

task test: %i[unit apps]
task default: :test
