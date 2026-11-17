class FollowsController < ActionController::Base
  # CRASH: the unique index keeps the data right, but the second request gets a 500.
  def follow
    Follow.create!(user_id: params[:user_id], target_id: params[:target_id])
    head :created
  rescue ActiveRecord::RecordInvalid
    head :unprocessable_entity
  end

  # RIGHT DATA, DIFFERENT REPLY: one at a time the validation turns the repeat away (422); at once
  # the repeat slips past the validation, hits the unique index and create_or_find_by finds the row (201).
  def mixed_follow
    Follow.create_or_find_by!(user_id: params[:user_id], target_id: params[:target_id])
    head :created
  end

  # FIXED: following twice is fine; a repeat finds the existing row, at once or one after the other.
  def safe_follow
    Follow.create_or_find_by!(user_id: params[:user_id], target_id: params[:target_id])
    head :created
  rescue ActiveRecord::RecordInvalid
    head :created
  end
end
