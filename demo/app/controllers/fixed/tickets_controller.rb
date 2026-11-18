# frozen_string_literal: true

module Fixed
  # 8. Fixed: the event row is locked while counting and selling.
  class TicketsController < ApplicationController
    def create
      event = Event.find(params[:event_id])
      sold = event.with_lock do
        next false if event.tickets.count >= event.capacity

        Ticket.create!(event: event, user: Current.user)
      end
      return render(plain: "Sold out", status: :unprocessable_entity) unless sold

      redirect_to root_path, notice: "See you at #{event.name}"
    end
  end
end
