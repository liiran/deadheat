# frozen_string_literal: true

class TeamsController < ActionController::Base
  before_action :authenticate_member!

  # BUG: checks the budget in Ruby, then subtracts in the database. `decrement!` is atomic, so this
  # looks safe, but two teammates can both pass the check and take the budget below zero.
  def spend
    team = current_member.team
    amount = params[:amount].to_i
    return render(plain: "Not enough budget", status: :unprocessable_entity) if team.budget < amount

    team.decrement!(:budget, amount)
    head :ok
  end

  # FIXED: the database only takes the money if it's there.
  def safe_spend
    amount = params[:amount].to_i
    taken = Team.where(id: current_member.team_id).where("budget >= ?", amount).update_all(["budget = budget - ?", amount])
    taken == 1 ? head(:ok) : render(plain: "Not enough budget", status: :unprocessable_entity)
  end
end
