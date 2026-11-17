require_relative "lib/deadheat/version"

Gem::Specification.new do |spec|
  spec.name = "deadheat"
  spec.version = Deadheat::VERSION
  spec.authors = ["Liran"]
  spec.summary = "Finds the bugs in a Rails app that only happen when two requests arrive at once."
  spec.description = <<~TEXT
    Dead Heat sends the write requests your tests already make twice at the same moment and compares
    the result with sending them one after the other. It reports double orders, coupons used twice,
    lost updates and duplicate records, shows the database queries of both requests side by side,
    suggests a fix and writes a regression test.
  TEXT
  spec.homepage = "https://github.com/liiran/deadheat"
  spec.required_ruby_version = ">= 3.2"

  spec.files = Dir["lib/**/*", "app/**/*", "config/**/*", "exe/*", "README.md"]
  spec.bindir = "exe"
  spec.executables = ["deadheat"]
  spec.require_paths = ["lib"]

  spec.add_dependency "activerecord", ">= 7.1", "< 9"
  spec.add_dependency "actionpack", ">= 7.1", "< 9"
  spec.add_dependency "railties", ">= 7.1", "< 9"
  spec.add_dependency "prism", ">= 1.2"
end
