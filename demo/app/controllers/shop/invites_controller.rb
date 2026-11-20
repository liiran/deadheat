# frozen_string_literal: true

module Shop
  # RACY ON PURPOSE: don't copy this file. The safe version is app/controllers/fixed/invites_controller.rb.
  #
  # 10. An invite code that works a limited number of times. Checks the uses, then joins.
  class InvitesController < ApplicationController
    def accept
      invite = Invite.find_by!(code: params[:code])
      return render(plain: "This invite has been used up", status: :unprocessable_entity) if invite.uses >= invite.max_uses

      Membership.create!(user: Current.user, invite: invite)
      invite.increment!(:uses)
      redirect_to root_path, notice: "Welcome in"
    end
  end
end
