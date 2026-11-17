class TagsController < ActionController::Base
  # BUG on a table without a primary key: check, then insert.
  def tag
    unless Tagging.exists?(post_id: params[:post_id], tag: params[:tag])
      Tagging.create!(post_id: params[:post_id], tag: params[:tag])
    end
    head :ok
  end
end
