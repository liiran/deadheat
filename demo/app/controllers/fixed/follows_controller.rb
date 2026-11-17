module Fixed
  # 7. Fixed: a unique index, and create_or_find_by lets a repeat find the first one.
  class FollowsController < ApplicationController
    def create
      store = ::Store.find(params[:store_id])
      FixedFollow.create_or_find_by!(user: Current.user, store: store)
      redirect_to root_path, notice: "Following #{store.name}"
    end
  end
end
