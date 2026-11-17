module Shop
  # 6. The payment provider says an order was paid. Webhooks can arrive more than once, sometimes at
  # the same moment. Checks the order isn't paid yet, then ships it.
  class WebhooksController < ApplicationController
    allow_unauthenticated_access
    skip_forgery_protection

    def order_paid
      order = Order.find(params[:order_id])
      unless order.paid_at
        order.update!(paid_at: Time.current)
        Shipment.create!(order: order)
        ShipOrderJob.perform_later(order)
      end
      head :ok
    end
  end
end
