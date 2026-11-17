# Store admin. These write endpoints have no tests yet, so the sweep can't reach them; they show up
# in its coverage number.
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
