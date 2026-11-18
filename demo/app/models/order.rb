# frozen_string_literal: true

class Order < ApplicationRecord
  belongs_to :user
  belongs_to :product
  has_one :shipment
end
