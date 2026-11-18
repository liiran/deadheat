# frozen_string_literal: true

require "rails_helper"
require "deadheat/rspec"

# Dead Heat settings for race specs. Everything here is optional.
Deadheat.configure do |c|
  # How many times each race runs its actions together (each try pauses differently).
  # c.tries = 20

  # Columns that change on every request for reasons that aren't races.
  # c.ignore_columns "users.last_seen_at"

  # How a race spec signs a user in. Devise works without this.
  # The block runs inside that user's own session, like a spec body.
  # c.sign_in { |user| post user_session_path, params: { user: { email: user.email, password: "password" } } }
end

# Devise's request helpers, for `r.as(user)`.
RSpec.configure { |config| config.include Devise::Test::IntegrationHelpers, type: :race } if defined?(Devise)
