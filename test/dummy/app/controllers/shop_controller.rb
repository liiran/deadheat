# frozen_string_literal: true

class ShopController < ActionController::Base
  # BUG: reads the stock, decides, then writes it back. Two buyers can both see "1 left".
  def buy
    product = Product.find(params[:id])
    if product.stock.positive?
      order = Order.create!(product: product, token: SecureRandom.hex(8))
      product.update!(stock: product.stock - 1)
      OrderMailer.confirmation(order).deliver_now
      redirect_to "/orders/#{order.id}"
    else
      render plain: "Sold out", status: :unprocessable_entity
    end
  end

  # FIXED: the row is locked while deciding, so the second buyer waits and then sees 0.
  def safe_buy
    product = Product.find(params[:id])
    order = product.with_lock do
      next unless product.stock.positive?

      product.update!(stock: product.stock - 1)
      Order.create!(product: product, token: SecureRandom.hex(8))
    end
    return render(plain: "Sold out", status: :unprocessable_entity) unless order

    OrderMailer.confirmation(order).deliver_now
    redirect_to "/orders/#{order.id}"
  end
end
