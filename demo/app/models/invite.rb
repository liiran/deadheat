# frozen_string_literal: true

class Invite < ApplicationRecord
  has_many :memberships
end
