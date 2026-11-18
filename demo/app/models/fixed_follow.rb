# frozen_string_literal: true

class FixedFollow < ApplicationRecord
  belongs_to :user
  belongs_to :store
end
