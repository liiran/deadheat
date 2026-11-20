# frozen_string_literal: true

# The pages a shopper sees. Plain on purpose: Corner Store exists to show Dead Heat at work.
class PagesController < ApplicationController
  allow_unauthenticated_access only: %i[home product]

  def home
    render plain: "Corner Store"
  end

  def product
    product = Product.find(params[:id])
    render plain: "#{product.name}: #{product.stock} left"
  end

  def order
    order = Order.where(user: Current.user).find(params[:id]) # only your own orders
    render plain: "Order #{order.id}: #{order.product.name}"
  end

  def cart
    render plain: "Your cart"
  end
end
