# frozen_string_literal: true

class GiftCardCharge < ApplicationRecord
  belongs_to :gift_card
  belongs_to :user
end
