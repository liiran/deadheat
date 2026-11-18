# frozen_string_literal: true

Rails.application.routes.draw do
  devise_for :members
  post "/team/spend", to: "teams#spend"
  post "/team/safe_spend", to: "teams#safe_spend"
  post "/buy/:id", to: "shop#buy"
  post "/safe_buy/:id", to: "shop#safe_buy"
  post "/like/:id", to: "likes#like"
  post "/safe_like/:id", to: "likes#safe_like"
  post "/signup", to: "accounts#signup"
  post "/safe_signup", to: "accounts#safe_signup"
  post "/follow", to: "follows#follow"
  post "/safe_follow", to: "follows#safe_follow"
  post "/mixed_follow", to: "follows#mixed_follow"
  patch "/documents/:id", to: "documents#rename"
  post "/tag", to: "tags#tag"
end
