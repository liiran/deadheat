# frozen_string_literal: true

class Member < ApplicationRecord
  devise :database_authenticatable, :trackable
  belongs_to :team
end
