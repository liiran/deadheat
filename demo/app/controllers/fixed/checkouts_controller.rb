# frozen_string_literal: true

module Fixed
  # 1. Fixed: the product row is locked while deciding, so the second buyer waits and sees 0.
  class CheckoutsController < ApplicationController
    def create
      product = Product.find(params[:product_id])
      order = product.with_lock do
        next if product.stock < 1

        product.update!(stock: product.stock - 1)
        Order.create!(user: Current.user, product: product, total_cents: product.price_cents)
      end
      return redirect_to(product_path(product), alert: "Sold out") unless order

      OrderMailer.confirmation(order).deliver_later
      redirect_to order_path(order), notice: "Thanks for your order"
    end
  end
end
