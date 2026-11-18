# frozen_string_literal: true

module Fixed
  # 5. Fixed: the database adds one.
  class ReviewsController < ApplicationController
    def helpful
      review = Review.find(params[:id])
      Review.update_counters(review.id, helpful_count: 1)
      redirect_to product_path(review.product)
    end
  end
end
