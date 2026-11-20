# frozen_string_literal: true

module Shop
  # RACY ON PURPOSE: don't copy this file. The safe version is app/controllers/fixed/wallets_controller.rb.
  #
  # 9. Withdrawing store credit. Checks the balance in Ruby; the decrement itself is atomic, which
  # makes this look safe.
  class WalletsController < ApplicationController
    def withdraw
      wallet = Wallet.find_by!(user: Current.user)
      amount = params[:amount_cents].to_i
      return render(plain: "Enter an amount above zero", status: :unprocessable_entity) unless amount.positive?

      return render(plain: "Not enough credit", status: :unprocessable_entity) if wallet.balance_cents < amount

      Withdrawal.create!(wallet: wallet, amount_cents: amount)
      wallet.decrement!(:balance_cents, amount)
      redirect_to root_path, notice: "Withdrawn"
    end
  end
end
