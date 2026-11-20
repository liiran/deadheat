# frozen_string_literal: true

module Shop
  # RACY ON PURPOSE: don't copy this file. The safe version is app/controllers/fixed/gift_cards_controller.rb.
  #
  # 3. Paying with a gift card. Checks the balance, then subtracts in Ruby.
  class GiftCardsController < ApplicationController
    def spend
      card = GiftCard.find_by!(code: params[:code])
      amount = params[:amount_cents].to_i
      return render(plain: "Enter an amount above zero", status: :unprocessable_entity) unless amount.positive?

      return render(plain: "Not enough on this card", status: :unprocessable_entity) if card.balance_cents < amount

      GiftCardCharge.create!(gift_card: card, user: Current.user, amount_cents: amount)
      card.update!(balance_cents: card.balance_cents - amount)
      redirect_to cart_path, notice: "Paid with your gift card"
    end
  end
end
