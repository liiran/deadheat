# frozen_string_literal: true

module Fixed
  # 10. Fixed: the invite is locked while checking and using it.
  class InvitesController < ApplicationController
    def accept
      invite = Invite.find_by!(code: params[:code])
      joined = invite.with_lock do
        next false if invite.uses >= invite.max_uses

        Membership.create!(user: Current.user, invite: invite)
        invite.increment!(:uses)
      end
      return render(plain: "This invite has been used up", status: :unprocessable_entity) unless joined

      redirect_to root_path, notice: "Welcome in"
    end
  end
end
