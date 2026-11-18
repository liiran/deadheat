# frozen_string_literal: true

module Shop
  # 4. Newsletter signup. The model validates the email is unique; the table has no unique index.
  class SubscribersController < ApplicationController
    allow_unauthenticated_access

    def create
      subscriber = Subscriber.new(email: params[:email])
      if subscriber.save
        redirect_to root_path, notice: "You're subscribed"
      else
        render plain: subscriber.errors.full_messages.to_sentence, status: :unprocessable_entity
      end
    end
  end
end
