Spinrail.routes.draw do
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
    get "/secret", to: "secrets#show"
    get "/open", to: "secrets#open_door"
    resources :posts, only: [:index]
  end
  get "/home", to: "pages#home"
  get "/badge/:label", to: "pages#badge"
  get "/mark", to: "pages#mark"
  get "/files/*path", to: "pages#file", as: :files
  get "/numbers/:n", to: "pages#number", constraints: { n: /\d+/ }
  get "/numbers/:word", to: "pages#word"
  get "/i18n", to: "i18n#show"
  get "/report", to: Actions::Reports::Show
  post "/signups", to: Actions::Signups::Create
  get "/bare", to: "bare#show"
  get "/plain", to: "plain#show"
  resources :documents, only: %i[create show update destroy] do
    get :download, on: :member
    get :signed, on: :member
  end
  get "/plain/ids", to: "plain#ids"
  post "/plain/ids", to: "plain#ids"
  get "/uploads/new", to: "uploads#new"
  post "/uploads", to: "uploads#create"
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
  get "/models/nulls", to: "models#nulls"
  get "/models/big", to: "models#big"
  get "/models/joins", to: "models#joins"
  get "/models/shout", to: "models#shout"
  get "/models/enqueue", to: "models#enqueue"
  get "/models/legacy", to: "models#legacy"
  get "/models/serial", to: "models#serial"
  get "/models/cached", to: "models#cached"
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

  post "/login", to: "logins#create"
  post "/signup", to: "logins#signup"
  post "/session", to: "sessions#create"
  get "/session", to: "sessions#show"
  post "/session/logout", to: "sessions#destroy"
  get "/session/now", to: "sessions#now"
end
