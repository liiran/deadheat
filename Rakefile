# frozen_string_literal: true

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

desc "Install the Corner Store demo app's own gems, if they aren't there yet"
task "demo:bundle" do
  require "bundler"
  Bundler.with_unbundled_env do
    Dir.chdir(File.expand_path("demo", __dir__)) do
      system("bundle", "check", out: File::NULL, err: File::NULL) || system("bundle", "install") ||
        abort("Couldn't install the demo app's gems (demo/Gemfile)")
    end
  end
end

desc "Sweep the Corner Store demo app end to end (slow; DB=postgres for one database)"
task "test:sweep" => "demo:bundle" do
  databases = ENV["DB"] ? [ENV["DB"]] : DATABASES
  failed = databases.reject do |db|
    puts "\n== sweep on #{db}"
    system({ "DB" => db }, Gem.ruby, "test/sweep/demo_sweep_test.rb")
  end
  abort "Sweep test failed on: #{failed.join(', ')}" if failed.any?
end
