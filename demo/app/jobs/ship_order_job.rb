# frozen_string_literal: true

# Asks the warehouse to ship an order. In a real store this calls the warehouse's API, and a second
# call ships a second parcel.
class ShipOrderJob < ApplicationJob
  def perform(order)
    Rails.logger.info("Shipping order #{order.id}")
  end
end
