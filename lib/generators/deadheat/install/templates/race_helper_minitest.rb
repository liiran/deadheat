# frozen_string_literal: true

require "test_helper"
require "deadheat/minitest"

# Dead Heat settings for race tests. Everything here is optional.
Deadheat.configure do |c|
  # How many times each race runs its actions together (each try pauses differently).
  # c.tries = 20

  # Columns that change on every request for reasons that aren't races.
  # c.ignore_columns "users.last_seen_at"

  # How a race test signs a user in. Devise and Rails 8's `sign_in_as` work without this.
  # The block runs inside that user's own session, like a test body.
  # c.sign_in { |user| post session_path, params: { email_address: user.email_address, password: "password" } }
end
