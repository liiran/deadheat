# frozen_string_literal: true

require "deadheat"
require "action_dispatch/testing/integration"

module Deadheat
  # Base class for race tests in Minitest:
  #
  #   class CheckoutRaceTest < Deadheat::RaceTest
  #     race "two buyers, one shirt" do |r|
  #       r.setup { @shirt = Product.create!(name: "Shirt", stock: 1) }
  #       r.as(users(:alice)) { post checkout_path, params: { product_id: @shirt.id } }
  #       r.as(users(:bob))   { post checkout_path, params: { product_id: @shirt.id } }
  #     end
  #   end
  #
  # Race tests commit real data (racing requests use their own database connections and can't see
  # uncommitted rows), so transactional tests are off here. Dead Heat puts every table back the way it
  # found it when the race ends.
  class RaceTest < ActionDispatch::IntegrationTest
    self.use_transactional_tests = false

    # Nothing a race test sets up is rolled back, so before any of it runs (fixtures, `setup` blocks)
    # this must be a test database. If the app uses DatabaseCleaner, it steps aside for race tests;
    # Dead Heat restores the tables.
    def before_setup
      Preflight.database!
      DatabaseCleanerPause.start_pause
      super
    end

    def after_teardown
      super
    ensure
      DatabaseCleanerPause.stop_pause
    end

    class << self
      def race(name, tries: nil, &definition)
        location = caller_locations(1, 1).first
        where = "#{location.path.sub("#{Dir.pwd}/", '')}:#{location.lineno}"
        test(name) do
          result = Deadheat::Race.new(self, name, tries: tries, location: where, &definition).run
          Deadheat::Results.save(result)
          assert result.passed?, -> { result.failure_message }
        end
      end
    end
  end
end
