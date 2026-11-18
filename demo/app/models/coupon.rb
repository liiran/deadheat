# frozen_string_literal: true

class Coupon < ApplicationRecord
  has_many :discounts
end
