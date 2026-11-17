# Spree 1ce4d2404 (March 2026) fixed a "gift card overspend race condition vulnerability": two orders
# applying the same gift card at once could both take its whole balance. Spree's fix came with a spec
# that starts five threads by hand; this is the same check as a Dead Heat race test.
require "spec_helper"
require "deadheat/rspec"

RSpec.describe Spree::GiftCards::Apply, type: :race do
  race "two orders spend one gift card at once" do |r|
    r.setup do
      store = Spree::Store.default
      @gift_card = create(:gift_card, amount: 100, store: store)
      @orders = Array.new(2) do
        order = create(:order, store: store, user: create(:user))
        order.update_columns(total: 80, item_total: 80)
        order
      end
    end
    2.times do |i|
      r.run("order #{i + 1}") do
        Spree::GiftCards::Apply.call(gift_card: Spree::GiftCard.find(@gift_card.id), order: Spree::Order.find(@orders[i].id))
      end
    end
    r.check("never spend more than the card holds") do
      Spree::StoreCredit.where(originator: @gift_card).sum(:amount) <= @gift_card.amount
    end
  end
end
