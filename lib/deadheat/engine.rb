require "deadheat/report"

module Deadheat
  # The /deadheat dashboard, for development:
  #   mount Deadheat::Engine => "/deadheat" if Rails.env.development?
  # It shows the same page as `bin/deadheat report`, for the latest run or any earlier one, and only
  # answers requests from this computer.
  class Engine < ::Rails::Engine
    isolate_namespace Deadheat

    routes.draw do
      root to: "reports#show"
      get "runs/:id", to: "reports#show", as: :run, constraints: { id: /[\w-]+/ }
    end
  end

  class ReportsController < ActionController::Base
    before_action { head :forbidden unless request.local? }

    def show
      run = Report.load(Rails.root.to_s, params[:id])
      return render(plain: "No results yet. Run bin/deadheat sweep or your race tests first.") unless run

      render html: Report.html(run).html_safe
    end
  end
end
