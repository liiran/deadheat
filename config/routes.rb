Deadheat::Engine.routes.draw do
  root to: "reports#show"
  get "runs/:id", to: "reports#show", as: :run, constraints: { id: /[\w-]+/ }
end
