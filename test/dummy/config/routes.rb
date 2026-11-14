Rieles.routes.draw do
  resources :posts do
    resources :comments, only: [:index, :new, :create, :show]
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
  get "/i18n", to: "i18n#show"
  get "/report", to: Actions::Reports::Show
  get "/bare", to: "bare#show"
  get "/plain", to: "plain#show"
  get "/models/seed", to: "models#seed"
  get "/models/query", to: "models#query"
  get "/models/validations", to: "models#validations"
  get "/models/associations", to: "models#associations"
  get "/models/transaction", to: "models#transaction"
  get "/models/bang", to: "models#bang"
  get "/models/scoped", to: "models#scoped"
  get "/models/authors", to: "models#authors"
  get "/models/eager", to: "models#eager"
  get "/models/abort", to: "models#abort"
  get "/models/signed", to: "models#signed"
  get "/models/scopes", to: "models#scopes"
  get "/models/formats", to: "models#formats"
  get "/models/cookie", to: "models#cookie"
  get "/models/helpers", to: "models#helpers"

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
