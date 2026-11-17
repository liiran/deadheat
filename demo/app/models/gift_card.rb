class GiftCard < ApplicationRecord
  has_many :charges, class_name: "GiftCardCharge"
end
