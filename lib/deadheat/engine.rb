require "deadheat/report"

module Deadheat
  # The /deadheat dashboard, for development:
  #   mount Deadheat::Engine => "/deadheat" if Rails.env.development?
  # It shows the same page as `bin/deadheat report`, for the latest run or any earlier one.
  #
  # The page shows queries and data from your test runs, so it answers only in development and test,
  # and only requests that come from this computer. Mounting it in production by mistake gives a 404.
  class Engine < ::Rails::Engine
    isolate_namespace Deadheat
    # Routes are in config/routes.rb at the gem's root: Rails reloads engine routes from there.

    LOOPBACK = /\A(?:127\.\d{1,3}\.\d{1,3}\.\d{1,3}|::1|0:0:0:0:0:0:0:1|::ffff:127\.\d{1,3}\.\d{1,3}\.\d{1,3})\z/
    LOCAL_HOST = /\A(?:localhost|127\.0\.0\.1|\[?::1\]?|[\w-]+\.localhost|[\w-]+\.test)\z/i

    # Is this request from this computer?
    # - The connection and the address Rails works out must both be loopback (`request.local?`).
    # - If a proxy passed the request on, every address it lists must be loopback too. Rails trusts
    #   private-network addresses there, which a visitor behind a local proxy could use to slip in.
    # - The page must have been asked for by a local name, which stops another website from reaching
    #   it through the browser (DNS rebinding).
    # A request forwarded by something that adds no headers at all (an SSH tunnel, a port forward)
    # looks local, so don't expose a development server that mounts this. DEADHEAT_DASHBOARD_ALLOW_REMOTE=1
    # turns the check off, for a development server inside a container.
    def self.local?(request)
      return true if ENV["DEADHEAT_DASHBOARD_ALLOW_REMOTE"] == "1"

      forwarded = request.get_header("HTTP_X_FORWARDED_FOR").to_s.split(/[\s,]+/).reject(&:empty?)
      request.local? &&
        forwarded.all? { |address| address.match?(LOOPBACK) } &&
        request.get_header("HTTP_FORWARDED").nil? &&
        request.host.to_s.match?(LOCAL_HOST)
    end
  end

  class ReportsController < ActionController::Base
    before_action :local_only

    def show
      run = Report.load(Rails.root.to_s, params[:id])
      if run.nil? && params[:id]
        return render(plain: "No such run.", status: :not_found)
      end
      return render(plain: "No results yet. Run bin/deadheat sweep or your race tests first.") unless run

      response.headers["Cache-Control"] = "no-store"
      response.headers["Content-Security-Policy"] = "default-src 'none'; style-src 'unsafe-inline'"
      response.headers["X-Content-Type-Options"] = "nosniff"
      render html: Report.html(run).html_safe # every value in the page is escaped by Report
    end

    private

    def local_only
      return head(:not_found) unless Rails.env.development? || Rails.env.test?

      head :forbidden unless Engine.local?(request)
    end
  end
end
