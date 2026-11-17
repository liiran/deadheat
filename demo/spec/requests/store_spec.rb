require "rails_helper"

# The same kind of ordinary tests as test/integration, written as RSpec request specs. They all pass.
# `bin/deadheat sweep --rspec` races them.
RSpec.describe "Corner Store", type: :request do
  before { sign_in_as users(:one) }

  %w[/ /fixed/].each do |prefix|
    describe "at #{prefix}" do
      it "sells the last one" do
        product = Product.create!(name: "Shirt", price_cents: 2500, stock: 1)
        post "#{prefix}products/#{product.id}/buy"
        expect(product.reload.stock).to eq(0)
      end

      it "redeems a one-use coupon" do
        Coupon.create!(code: "SAVE10", percent_off: 10)
        post "#{prefix}coupons/SAVE10/redeem"
        expect(Discount.count).to eq(1)
      end

      it "withdraws store credit" do
        wallet = Wallet.create!(user: users(:one), balance_cents: 5000)
        post "#{prefix}wallet/withdraw", params: { amount_cents: 4000 }
        expect(wallet.reload.balance_cents).to eq(1000)
      end

      it "follows a store" do
        store = Store.create!(name: "Corner Books")
        post "#{prefix}stores/#{store.id}/follow"
        expect(response).to redirect_to(root_path)
      end
    end
  end
end
