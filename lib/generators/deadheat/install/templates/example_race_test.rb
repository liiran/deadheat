require_relative "race_helper"

# A race test runs its actions at the same moment and fails if the result could never happen with
# one action after the other. Change this example to fit your app, or delete it: `bin/deadheat sweep`
# finds races without any race tests, and writes them for you when it does.
#
# class CheckoutRaceTest < Deadheat::RaceTest
#   race "two buyers, one shirt" do |r|
#     r.setup { @shirt = Product.create!(name: "Shirt", stock: 1) }
#     r.as(users(:one)) { post checkout_path, params: { product_id: @shirt.id } }
#     r.as(users(:two)) { post checkout_path, params: { product_id: @shirt.id } }
#     r.check("never sell more than we have") { Order.where(product_id: @shirt.id).count <= 1 }  # optional
#   end
#
#   race "the payment webhook arrives twice" do |r|
#     r.setup { @order = Order.create!(user: users(:one), product: products(:shirt)) }
#     r.twice { post webhooks_order_paid_path, params: { order_id: @order.id } }
#   end
# end
