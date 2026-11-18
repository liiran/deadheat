# frozen_string_literal: true

module Shop
  # 1. Buying the last one. Reads the stock, decides, then saves it.
  class CheckoutsController < ApplicationController
    def create
      product = Product.find(params[:product_id])
      if product.stock < 1
        redirect_to product_path(product), alert: "Sold out"
        return
      end

      order = Order.create!(user: Current.user, product: product, total_cents: product.price_cents)
      product.update!(stock: product.stock - 1)
      OrderMailer.confirmation(order).deliver_later
      redirect_to order_path(order), notice: "Thanks for your order"
    end
  end
end
