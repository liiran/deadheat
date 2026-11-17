require "rails"
require "active_record/railtie"
require "action_controller/railtie"
require "action_mailer/railtie"
require "active_job/railtie"
require "devise"
require "deadheat"

module Dummy
  # A small app with planted race conditions, each next to a fixed twin, for Dead Heat's own tests.
  class Application < Rails::Application
    config.load_defaults Rails::VERSION::STRING.to_f
    config.root = File.expand_path("..", __dir__)
    config.eager_load = false
    config.enable_reloading = false
    config.logger = Logger.new(nil)
    config.secret_key_base = "dummy" * 16
    config.hosts.clear
    config.active_support.deprecation = :stderr
    config.action_controller.allow_forgery_protection = false
    config.action_mailer.delivery_method = :test
    config.action_mailer.default_url_options = { host: "example.com" }
    config.active_job.queue_adapter = :test
    config.active_record.maintain_test_schema = false
  end
end
