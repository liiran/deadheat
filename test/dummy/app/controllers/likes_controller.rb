class LikesController < ActionController::Base
  # BUG: adds one in Ruby and saves; two likes at once save the same number.
  def like
    post = Post.find(params[:id])
    post.update!(likes_count: post.likes_count + 1)
    head :ok
  end

  # FIXED: the database adds one.
  def safe_like
    Post.update_counters(params[:id], likes_count: 1)
    head :ok
  end
end
