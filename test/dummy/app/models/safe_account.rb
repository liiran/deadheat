# frozen_string_literal: true

class SafeAccount < ApplicationRecord
  validates :email, presence: true, uniqueness: true
end
