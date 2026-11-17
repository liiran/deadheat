require "deadheat"

module Deadheat
  # Race tests in RSpec. In spec/races/checkout_race_spec.rb:
  #
  #   require "rails_helper"
  #   require "deadheat/rspec"
  #
  #   RSpec.describe "Checkout", type: :race do
  #     race "two buyers, one shirt" do |r|
  #       r.setup { @shirt = Product.create!(name: "Shirt", stock: 1) }
  #       r.as(users(:alice)) { post checkout_path, params: { product_id: @shirt.id } }
  #       r.as(users(:bob))   { post checkout_path, params: { product_id: @shirt.id } }
  #     end
  #   end
  #
  # `type: :race` groups behave like request specs (post, get, open_session…) with transactional
  # fixtures off: racing requests use their own connections and can't see uncommitted rows. Dead Heat
  # puts every table back the way it found it when the race ends.
  module RSpec
    module ExampleGroup
      extend ActiveSupport::Concern
      include ::RSpec::Rails::RequestExampleGroup

      included do
        self.use_transactional_tests = false if respond_to?(:use_transactional_tests=)
      end

      class_methods do
        def race(name, tries: nil, **metadata, &definition)
          location = caller_locations(1, 1).first
          where = "#{location.path.sub("#{Dir.pwd}/", '')}:#{location.lineno}"
          it(name, **metadata) do
            result = Deadheat::Race.new(self, name, tries: tries, location: where, &definition).run
            Deadheat::Results.save(result)
            expect(result.passed?).to be(true), result.failure_message
          end
        end
      end
    end
  end
end

::RSpec.configure do |config|
  config.include Deadheat::RSpec::ExampleGroup, type: :race
end
