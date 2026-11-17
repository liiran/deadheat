Rails.application.routes.draw do
  resource :session
  resources :passwords, param: :token

  root "pages#home"
  get "products/:id", to: "pages#product", as: :product
  get "orders/:id", to: "pages#order", as: :order
  get "cart", to: "pages#cart", as: :cart

  # The store, with ten race conditions planted in it. Every one has a passing test.
  scope module: :shop do
    post "products/:product_id/buy", to: "checkouts#create"
    post "coupons/:code/redeem", to: "coupons#redeem"
    post "gift_cards/:code/spend", to: "gift_cards#spend"
    post "newsletter", to: "subscribers#create"
    post "reviews/:id/helpful", to: "reviews#helpful"
    post "webhooks/order_paid", to: "webhooks#order_paid"
    post "stores/:store_id/follow", to: "follows#create"
    post "events/:event_id/tickets", to: "tickets#create"
    post "wallet/withdraw", to: "wallets#withdraw"
    post "invites/:code/accept", to: "invites#accept"
  end

  # The same ten features, fixed.
  namespace :fixed do
    post "products/:product_id/buy", to: "checkouts#create"
    post "coupons/:code/redeem", to: "coupons#redeem"
    post "gift_cards/:code/spend", to: "gift_cards#spend"
    post "newsletter", to: "subscribers#create"
    post "reviews/:id/helpful", to: "reviews#helpful"
    post "webhooks/order_paid", to: "webhooks#order_paid"
    post "stores/:store_id/follow", to: "follows#create"
    post "events/:event_id/tickets", to: "tickets#create"
    post "wallet/withdraw", to: "wallets#withdraw"
    post "invites/:code/accept", to: "invites#accept"
  end

  # Admin endpoints without tests: the sweep can't reach these.
  post "admin/products/:id/restock", to: "admin#restock"
  delete "admin/orders/:id", to: "admin#cancel_order"

  get "up" => "rails/health#show", as: :rails_health_check
end
