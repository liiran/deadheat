# frozen_string_literal: true

class Follow < ApplicationRecord
  validates :target_id, uniqueness: { scope: :user_id }
end
