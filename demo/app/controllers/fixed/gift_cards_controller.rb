# frozen_string_literal: true

module Fixed
  # 3. Fixed: the card is locked while checking and charging.
  class GiftCardsController < ApplicationController
    def spend
      card = GiftCard.find_by!(code: params[:code])
      amount = params[:amount_cents].to_i
      return render(plain: "Enter an amount above zero", status: :unprocessable_entity) unless amount.positive?

      paid = card.with_lock do
        next false if card.balance_cents < amount

        GiftCardCharge.create!(gift_card: card, user: Current.user, amount_cents: amount)
        card.update!(balance_cents: card.balance_cents - amount)
      end
      return render(plain: "Not enough on this card", status: :unprocessable_entity) unless paid

      redirect_to cart_path, notice: "Paid with your gift card"
    end
  end
end
