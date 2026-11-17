module Deadheat
  class Railtie < Rails::Railtie
    # The sign-in warm-up endpoint, in the test environment only. It goes right after Warden when
    # Devise is used, so Devise's queued login is written into that request's session.
    # It's a route, not middleware, so the request passes through every middleware (Warden, the
    # session) whatever order they were added in.
    initializer "deadheat.ping" do |app|
      next unless Rails.env.test?

      app.routes.prepend do
        get Deadheat::Ping::PATH, to: Deadheat::Ping.endpoint, as: :deadheat_ping
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
