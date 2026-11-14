Rieles.routes.draw do
  resources :posts do
    resources :comments, only: [:index, :create, :show]
    member do
      post :publish
    end
    collection do
      get :search
    end
  end
  resource :profile, only: [:show]
  namespace :admin do
    root "posts#index"
    resources :posts, only: [:index]
  end
  get "/home", to: "pages#home"
  get "/bare", to: "bare#show"
  get "/plain", to: "plain#show"
  get "/models/seed", to: "models#seed"
  get "/models/query", to: "models#query"
  get "/models/validations", to: "models#validations"
  get "/models/associations", to: "models#associations"
  get "/models/transaction", to: "models#transaction"
  get "/models/bang", to: "models#bang"

  get "/widgets", to: "widgets#index"
  get "/widgets/:id", to: "widgets#show"
  patch "/widgets/:id", to: "widgets#update"
  delete "/widgets/:id", to: "widgets#destroy"
  get "/open", to: "widgets#open"
  get "/boom", to: "widgets#boom"

  post "/session", to: "sessions#create"
  get "/session", to: "sessions#show"
  post "/session/logout", to: "sessions#destroy"
  get "/session/now", to: "sessions#now"
end
