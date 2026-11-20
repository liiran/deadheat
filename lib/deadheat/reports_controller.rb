# frozen_string_literal: true

module Deadheat
  # The dashboard's one page. It only reads the results folder, and only for this computer in
  # development and test (see Engine.local?).
  class ReportsController < ActionController::Base
    before_action :local_only

    def show
      run = Report.load(Rails.root.to_s, params[:id])
      if run.nil? && params[:id]
        return render(plain: "No such run.", status: :not_found)
      end
      return render(plain: "No results yet. Run bin/deadheat sweep or your race tests first.") unless run

      response.headers["Cache-Control"] = "no-store"
      response.headers["Content-Security-Policy"] = "#{Report::CONTENT_POLICY}; frame-ancestors 'none'"
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
