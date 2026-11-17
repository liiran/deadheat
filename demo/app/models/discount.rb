class Discount < ApplicationRecord
  belongs_to :user
  belongs_to :coupon
end
