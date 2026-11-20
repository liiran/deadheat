# frozen_string_literal: true

module Fixed
  # 9. Fixed: the database only takes the credit if it's there.
  class WalletsController < ApplicationController
    def withdraw
      wallet = Wallet.find_by!(user: Current.user)
      amount = params[:amount_cents].to_i
      return render(plain: "Enter an amount above zero", status: :unprocessable_entity) unless amount.positive?

      taken = Wallet.where(id: wallet.id).where("balance_cents >= ?", amount).update_all(["balance_cents = balance_cents - ?", amount]) == 1
      return render(plain: "Not enough credit", status: :unprocessable_entity) unless taken

      Withdrawal.create!(wallet: wallet, amount_cents: amount)
      redirect_to root_path, notice: "Withdrawn"
    end
  end
end
