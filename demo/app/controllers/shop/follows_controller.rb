# frozen_string_literal: true

module Shop
  # RACY ON PURPOSE: don't copy this file. The safe version is app/controllers/fixed/follows_controller.rb.
  #
  # 7. Following a store. Looks for an existing follow, creates one if there isn't.
  class FollowsController < ApplicationController
    def create
      store = ::Store.find(params[:store_id])
      Follow.find_by(user: Current.user, store: store) || Follow.create!(user: Current.user, store: store)
      redirect_to root_path, notice: "Following #{store.name}"
    end
  end
end
