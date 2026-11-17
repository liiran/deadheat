ENV["RAILS_ENV"] = "test"
ENV["DEADHEAT_DB_NAME"] ||= "deadheat_rspec_test"
ENV["DEADHEAT_TRIES"] ||= "12"
$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require_relative "../dummy/config/environment"
require "rspec/rails"
require_relative "../support/database"
require "deadheat/rspec"

Deadheat.config.results_dir = File.expand_path("../../tmp/deadheat", __dir__)

RSpec.configure do |config|
  config.use_transactional_fixtures = true
  config.include Devise::Test::IntegrationHelpers, type: :race
end
