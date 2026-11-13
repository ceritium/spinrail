Rieles.routes.draw do
  root "entries#index"
  resources :entries, only: [:index, :show, :create]
end
