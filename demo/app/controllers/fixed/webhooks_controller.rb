# frozen_string_literal: true

module Fixed
  # 6. Fixed: marking the order paid is the check, and a unique index allows one shipment per order.
  class WebhooksController < ApplicationController
    # A real webhook must check the provider's signature before believing the request. The demo
    # leaves that out, so anyone could mark an order paid: add it before using this anywhere.
    allow_unauthenticated_access
    skip_forgery_protection

    def order_paid
      order = Order.find(params[:order_id])
      if Order.where(id: order.id, paid_at: nil).update_all(paid_at: Time.current) == 1
        FixedShipment.create!(order: order)
        ShipOrderJob.perform_later(order)
      end
      head :ok
    end
  end
end
