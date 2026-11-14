class Admin::SecretsController < ApplicationController
  http_basic_authenticate_with name: "admin", password: ENV.fetch("ADMIN_PASSWORD", "s3cret"), except: [:open_door]

  def show
    render plain: "the secret"
  end

  def open_door
    render plain: "open"
  end
end
