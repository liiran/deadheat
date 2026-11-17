module Fixed
  # 4. Fixed: a unique index stops the duplicate, and the conflict is answered like the validation.
  class SubscribersController < ApplicationController
    allow_unauthenticated_access

    def create
      subscriber = FixedSubscriber.new(email: params[:email])
      if subscriber.save
        redirect_to root_path, notice: "You're subscribed"
      else
        render plain: subscriber.errors.full_messages.to_sentence, status: :unprocessable_entity
      end
    rescue ActiveRecord::RecordNotUnique
      render plain: "Email has already been taken", status: :unprocessable_entity
    end
  end
end
