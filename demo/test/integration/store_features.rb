# frozen_string_literal: true

# One ordinary test per feature, the kind any app already has. They all pass: sending one request at a
# time, every feature works. ShopTest runs them against the store, FixedShopTest against the fixed
# twins under /fixed.
module StoreFeatures
  extend ActiveSupport::Concern

  class << self
    # Five features have a limit: stock, a card's balance, seats, store credit, an invite's uses.
    # These tests sit right at it (the last shirt, the last seat), which is what lets a request sent
    # twice cross it. ROOM=1 runs them with room to spare instead. bench/tools_bench.rb measures the
    # sweep both ways, to show which races it finds only from a test at the limit.
    def roomy? = ENV["ROOM"] == "1"
  end

  included do
    setup { sign_in_as users(:one) }

    test "buying the last one" do
      stock = StoreFeatures.roomy? ? 5 : 1
      product = Product.create!(name: "Shirt", price_cents: 2500, stock: stock)
      post "#{prefix}/products/#{product.id}/buy"
      assert_redirected_to order_path(Order.last)
      assert_equal stock - 1, product.reload.stock
    end

    test "redeeming a one-use coupon" do
      Coupon.create!(code: "SAVE10", percent_off: 10)
      post "#{prefix}/coupons/SAVE10/redeem"
      assert_redirected_to cart_path
      assert_equal 1, Discount.count
    end

    test "paying with a gift card" do
      card = GiftCard.create!(code: "GIFT-1", balance_cents: 5000)
      amount = StoreFeatures.roomy? ? 1000 : 4000
      post "#{prefix}/gift_cards/GIFT-1/spend", params: { amount_cents: amount }
      assert_redirected_to cart_path
      assert_equal 5000 - amount, card.reload.balance_cents
    end

    test "subscribing to the newsletter" do
      post "#{prefix}/newsletter", params: { email: "sam@example.com" }
      assert_redirected_to root_path
    end

    test "marking a review helpful" do
      product = Product.create!(name: "Mug", price_cents: 1200, stock: 5)
      review = product.reviews.create!(body: "Great mug")
      post "#{prefix}/reviews/#{review.id}/helpful"
      assert_equal 1, review.reload.helpful_count
    end

    test "a paid order ships once" do
      product = Product.create!(name: "Lamp", price_cents: 4000, stock: 3)
      order = Order.create!(user: users(:one), product: product, total_cents: 4000)
      post "#{prefix}/webhooks/order_paid", params: { order_id: order.id }
      assert_response :ok
      assert order.reload.paid_at
      assert_enqueued_jobs 1, only: ShipOrderJob
    end

    test "following a store" do
      store = Store.create!(name: "Corner Books")
      post "#{prefix}/stores/#{store.id}/follow"
      assert_redirected_to root_path
    end

    test "buying a ticket to a nearly full event" do
      event = Event.create!(name: "Launch party", capacity: StoreFeatures.roomy? ? 100 : 1)
      post "#{prefix}/events/#{event.id}/tickets"
      assert_redirected_to root_path
      assert_equal 1, event.tickets.count
    end

    test "withdrawing store credit" do
      wallet = Wallet.create!(user: users(:one), balance_cents: 5000)
      amount = StoreFeatures.roomy? ? 1000 : 4000
      post "#{prefix}/wallet/withdraw", params: { amount_cents: amount }
      assert_redirected_to root_path
      assert_equal 5000 - amount, wallet.reload.balance_cents
    end

    test "accepting a single-use invite" do
      Invite.create!(code: "JOIN-ME", max_uses: StoreFeatures.roomy? ? 5 : 1)
      post "#{prefix}/invites/JOIN-ME/accept"
      assert_redirected_to root_path
      assert_equal 1, Membership.count
    end
  end
end
