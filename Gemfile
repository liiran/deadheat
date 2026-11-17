source "https://rubygems.org"

gemspec

# RAILS=7.1 (or 7.2, 8.0, 8.1) picks the Rails version the tests run against.
rails = ENV.fetch("RAILS", "8.1")
gem "rails", "~> #{rails}.0"

gem "rake"
gem "minitest", rails == "7.2" ? "< 6" : ">= 5"
gem "pg"
gem "mysql2"
gem "trilogy"
gem "sqlite3", rails < "8.0" ? "~> 1.7" : ">= 2.1"
gem "rspec-rails"
gem "devise"
gem "webmock"
