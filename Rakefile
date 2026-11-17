require "rake/testtask"

DATABASES = %w[sqlite postgres mysql].freeze

namespace :test do
  Rake::TestTask.new(:once) do |t|
    t.libs << "test"
    t.test_files = FileList["test/unit/**/*_test.rb", "test/races/**/*_test.rb"]
    t.warning = false
  end
end

desc "Run the tests on every database (DB=postgres for one)"
task :test do
  databases = ENV["DB"] ? [ENV["DB"]] : DATABASES
  failed = databases.reject do |db|
    puts "\n== #{db}"
    system({ "DB" => db }, Gem.ruby, "-S", "rake", "test:once")
  end
  abort "Failed on: #{failed.join(', ')}" if failed.any?
end

task default: :test
