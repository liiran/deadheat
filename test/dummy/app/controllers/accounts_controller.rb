class AccountsController < ActionController::Base
  # BUG: the uniqueness validation checks, then inserts; with no unique index two signups both pass.
  def signup
    account = Account.new(email: params[:email])
    if account.save
      head :created
    else
      head :unprocessable_entity
    end
  end

  # FIXED: a unique index stops the second one, and the conflict is handled.
  def safe_signup
    account = SafeAccount.new(email: params[:email])
    if account.save
      head :created
    else
      head :unprocessable_entity
    end
  rescue ActiveRecord::RecordNotUnique
    head :unprocessable_entity
  end
end
