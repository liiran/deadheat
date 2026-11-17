module Deadheat
  class Railtie < Rails::Railtie
    # The sign-in warm-up endpoint, in the test environment only. It goes right after Warden when
    # Devise is used, so Devise's queued login is written into that request's session.
    initializer "deadheat.ping" do |app|
      next unless Rails.env.test?

      if defined?(Warden::Manager)
        app.config.middleware.insert_after Warden::Manager, Deadheat::Ping
      else
        app.config.middleware.use Deadheat::Ping
      end
    end

    # While `deadheat sweep` runs the tests, watch every integration test and request spec.
    initializer "deadheat.sweep" do
      next unless Rails.env.test? && %w[record race].include?(ENV["DEADHEAT_SWEEP"])

      ActiveSupport.on_load(:action_dispatch_integration_test) { require "deadheat/sweep/minitest" }
      require "deadheat/sweep/rspec" if defined?(::RSpec::Core)
    end

    rake_tasks do
      load File.expand_path("tasks/deadheat.rake", __dir__) if File.exist?(File.expand_path("tasks/deadheat.rake", __dir__))
    end
  end
end
