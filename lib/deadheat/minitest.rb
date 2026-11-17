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
