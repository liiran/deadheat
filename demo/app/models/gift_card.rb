# frozen_string_literal: true

class GiftCard < ApplicationRecord
  has_many :charges, class_name: "GiftCardCharge"
end
