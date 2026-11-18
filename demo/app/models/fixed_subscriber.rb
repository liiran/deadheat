# frozen_string_literal: true

class FixedSubscriber < ApplicationRecord
  # Emails are stored lower-case, so the unique index on email covers every spelling.
  normalizes :email, with: ->(email) { email.strip.downcase }
  validates :email, presence: true, uniqueness: true
end
