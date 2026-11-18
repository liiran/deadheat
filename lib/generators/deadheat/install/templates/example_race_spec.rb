# frozen_string_literal: true

require_relative "race_helper"

# A race spec runs its actions at the same moment and fails if the result could never happen with
# one action after the other. Change this example to fit your app, or delete it: `bin/deadheat sweep`
# finds races without any race specs, and writes them for you when it does.
#
# RSpec.describe "Checkout", type: :race do
#   let(:shirt) { Product.create!(name: "Shirt", stock: 1) }
#
#   race "two buyers, one shirt" do |r|
#     r.as(:alice, sign_in: -> { create(:user) }) { post checkout_path, params: { product_id: shirt.id } }
#     r.as(:bob, sign_in: -> { create(:user) }) { post checkout_path, params: { product_id: shirt.id } }
#     r.check("never sell more than we have") { Order.where(product_id: shirt.id).count <= 1 }  # optional
#   end
#
#   race "the payment webhook arrives twice" do |r|
#     r.twice { post webhooks_order_paid_path, params: { order_id: create(:order).id } }
#   end
# end
