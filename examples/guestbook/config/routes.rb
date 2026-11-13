Rieles.routes.draw do
  root "entries#index"
  resources :entries, only: [:index, :show, :create]
  get "/stats", to: "stats.show"
  get "/summary", to: "entries#summary"
end
