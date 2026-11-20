# frozen_string_literal: true

module Shop
  # RACY ON PURPOSE: don't copy this file. The safe version is app/controllers/fixed/coupons_controller.rb.
  #
  # 2. A one-use coupon. Checks it hasn't been used, then marks it used.
  class CouponsController < ApplicationController
    def redeem
      coupon = Coupon.find_by!(code: params[:code])
      return render(plain: "That coupon has already been used", status: :unprocessable_entity) if coupon.used_at

      Discount.create!(user: Current.user, coupon: coupon, percent_off: coupon.percent_off)
      coupon.update!(used_at: Time.current)
      redirect_to cart_path, notice: "#{coupon.percent_off}% off applied"
    end
  end
end
