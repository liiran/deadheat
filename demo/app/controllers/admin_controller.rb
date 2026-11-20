# frozen_string_literal: true

# Store admin. These write endpoints have no tests yet, so the sweep can't reach them; they show up
# in its coverage number.
#
# Not an example to copy: nothing checks that the signed-in user is an admin, and `restock` reads
# the stock and writes it back (an eleventh race, which `bin/deadheat scan` points out).
class AdminController < ApplicationController
  def restock
    product = Product.find(params[:id])
    product.update!(stock: product.stock + params[:amount].to_i)
    head :ok
  end

  def cancel_order
    Order.find(params[:id]).destroy!
    head :ok
  end
end
