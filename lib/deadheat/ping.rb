# frozen_string_literal: true

module Deadheat
  # A tiny test-only route. Some sign-in helpers (Devise's) don't sign in right away: they queue the
  # login for "the next request", and that queue is shared by the whole process. Dead Heat signs each
  # racing session in one at a time with a request to this endpoint, which goes through Warden and the session like any
  # request, so the login lands in that session's cookie.
  module Ping
    PATH = "/__deadheat/ping"

    class << self
      def endpoint
        ->(_env) { [204, { "cache-control" => "no-store" }, []] }
      end
    end
  end
end
