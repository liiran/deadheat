# frozen_string_literal: true

require "uri"
require "deadheat/report"

module Deadheat
  # Loaded the first time the dashboard is asked for, not when the app boots: a controller defined at
  # boot would load Action Controller before the app's own initializers have configured it.
  autoload :ReportsController, "deadheat/reports_controller"

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
    # Headers a proxy uses to name the visitor it is passing on. A browser talking straight to this
    # computer sends none of them.
    CLIENT_ADDRESS_HEADERS = %w[
      HTTP_X_FORWARDED_FOR HTTP_X_REAL_IP HTTP_CLIENT_IP HTTP_X_CLIENT_IP HTTP_TRUE_CLIENT_IP
      HTTP_CF_CONNECTING_IP HTTP_X_CLUSTER_CLIENT_IP HTTP_FASTLY_CLIENT_IP
    ].freeze
    PROXY_HEADERS = %w[HTTP_FORWARDED HTTP_VIA].freeze

    class << self
      # Is this request from this computer, and from the person at it?
      # - The connection and the address Rails works out must both be loopback (`request.local?`).
      # - If a proxy passed the request on, every address it lists (in X-Forwarded-For, X-Real-IP and
      #   the like) must be loopback too. Rails trusts private-network addresses there, which a visitor
      #   behind a local proxy could use to slip in. A Forwarded or Via header is refused outright.
      # - The page must have been asked for by a local name, which stops another website from reaching
      #   it through the browser (DNS rebinding). Both the Host header and X-Forwarded-Host count.
      # - It must not be another website's script reading the page through the browser.
      # A request forwarded by something that adds no headers at all (an SSH tunnel, a port forward)
      # looks local, so don't expose a development server that mounts this.
      #
      # DEADHEAT_DASHBOARD_ALLOW_REMOTE=1 drops the address checks, for a development server inside a
      # container (which sees your browser as another computer). The name and other-website checks stay.
      def local?(request)
        return false unless named_locally?(request) && !from_another_site?(request)
        return true if allow_remote?

        forwarded = CLIENT_ADDRESS_HEADERS.flat_map { |name| request.get_header(name).to_s.split(/[\s,]+/) }.reject(&:empty?)
        request.local? &&
          forwarded.all? { |address| address.match?(LOOPBACK) } &&
          PROXY_HEADERS.none? { |name| request.get_header(name) }
      end

      def allow_remote?
        ENV["DEADHEAT_DASHBOARD_ALLOW_REMOTE"] == "1"
      end

      # Every name the request was made under is a local one. With DEADHEAT_DASHBOARD_ALLOW_REMOTE,
      # a name the app itself accepts (`config.hosts`, which Rails has already checked) will do.
      def named_locally?(request)
        hosts = hosts_of(request)
        return false if hosts.empty?
        return true if hosts.all? { |host| host.match?(LOCAL_HOST) }

        allow_remote? && Array(Rails.application.config.hosts).any?
      end

      def hosts_of(request)
        named = [request.get_header("HTTP_HOST"), *request.get_header("HTTP_X_FORWARDED_HOST").to_s.split(/\s*,\s*/)]
        named.compact.reject(&:empty?).map { |host| host.sub(/:\d+\z/, "") }
      end

      # A script on another website asking for the page (which only matters if the app lets other
      # origins read its responses). Following a link here from another site is fine.
      def from_another_site?(request)
        origin = request.get_header("HTTP_ORIGIN").to_s
        return true unless origin.empty? || hosts_of(request).include?(host_of(origin)) || host_of(origin).match?(LOCAL_HOST)

        request.get_header("HTTP_SEC_FETCH_SITE") == "cross-site" && request.get_header("HTTP_SEC_FETCH_MODE") != "navigate"
      end

      def host_of(origin)
        host = URI.parse(origin).host.to_s
        host.include?(":") && !host.start_with?("[") ? "[#{host}]" : host
      rescue URI::InvalidURIError
        ""
      end
    end
  end
end
