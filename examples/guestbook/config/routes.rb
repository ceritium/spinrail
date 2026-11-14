Spinrail.routes.draw do
  root "entries#index"
  resources :entries, only: [:index, :show, :create]
  get "/stats", to: Actions::Stats::Show
  get "/summary", to: "entries#summary"
end
