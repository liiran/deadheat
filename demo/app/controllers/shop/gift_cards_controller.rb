module Shop
  # 3. Paying with a gift card. Checks the balance, then subtracts in Ruby.
  class GiftCardsController < ApplicationController
    def spend
      card = GiftCard.find_by!(code: params[:code])
      amount = params[:amount_cents].to_i
      return render(plain: "Not enough on this card", status: :unprocessable_entity) if card.balance_cents < amount

      GiftCardCharge.create!(gift_card: card, user: Current.user, amount_cents: amount)
      card.update!(balance_cents: card.balance_cents - amount)
      redirect_to cart_path, notice: "Paid with your gift card"
    end
  end
end
