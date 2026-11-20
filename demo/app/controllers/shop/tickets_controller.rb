# frozen_string_literal: true

module Shop
  # RACY ON PURPOSE: don't copy this file. The safe version is app/controllers/fixed/tickets_controller.rb.
  #
  # 8. Tickets for an event with limited seats. Counts the tickets sold, then sells one.
  class TicketsController < ApplicationController
    def create
      event = Event.find(params[:event_id])
      return render(plain: "Sold out", status: :unprocessable_entity) if event.tickets.count >= event.capacity

      Ticket.create!(event: event, user: Current.user)
      redirect_to root_path, notice: "See you at #{event.name}"
    end
  end
end
