module Fixed
  # 2. Fixed: marking the coupon used is the check. Only one request can change used_at from empty.
  class CouponsController < ApplicationController
    def redeem
      coupon = Coupon.find_by!(code: params[:code])
      claimed = Coupon.where(id: coupon.id, used_at: nil).update_all(used_at: Time.current) == 1
      return render(plain: "That coupon has already been used", status: :unprocessable_entity) unless claimed

      Discount.create!(user: Current.user, coupon: coupon, percent_off: coupon.percent_off)
      redirect_to cart_path, notice: "#{coupon.percent_off}% off applied"
    end
  end
end
