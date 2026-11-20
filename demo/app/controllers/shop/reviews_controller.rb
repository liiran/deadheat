# frozen_string_literal: true

module Shop
  # RACY ON PURPOSE: don't copy this file. The safe version is app/controllers/fixed/reviews_controller.rb.
  #
  # 5. "Was this review helpful?" Adds one in Ruby and saves.
  class ReviewsController < ApplicationController
    def helpful
      review = Review.find(params[:id])
      review.update!(helpful_count: review.helpful_count + 1)
      redirect_to product_path(review.product)
    end
  end
end
