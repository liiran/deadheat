module Deadheat
  # A tiny test-only endpoint. Some sign-in helpers (Devise's) don't sign in right away: they queue the
  # login for "the next request", and that queue is shared by the whole process. Dead Heat signs each
  # racing session in one at a time with a request to this endpoint, which sits after Warden in the
  # middleware so the login lands in that session's cookie.
  class Ping
    PATH = "/__deadheat/ping".freeze

    def initialize(app)
      @app = app
    end

    def call(env)
      return [204, { "cache-control" => "no-store" }, []] if env["PATH_INFO"] == PATH

      @app.call(env)
    end
  end
end
