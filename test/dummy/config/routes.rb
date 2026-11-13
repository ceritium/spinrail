Rieles.routes.draw do
  get "/models/seed", to: "models#seed"
  get "/models/query", to: "models#query"
  get "/models/validations", to: "models#validations"
  get "/models/associations", to: "models#associations"
  get "/models/transaction", to: "models#transaction"
  get "/models/bang", to: "models#bang"
end
