class LoginsController < ApplicationController
  def create
    user = User.find_by(email: params[:email])
    if user && user.authenticate(params[:password])
      session[:user_id] = user.id
      render plain: "welcome " + user.email
    else
      render plain: "denied", status: :unauthorized
    end
  end

  def signup
    user = User.new(signup_params)
    if user.save
      if params[:later] == "1"
        UserMailer.welcome(user).deliver_later
      else
        UserMailer.welcome(user).deliver_now
      end
      render plain: "created " + user.to_json
    else
      render plain: user.errors.full_messages.join(", "), status: :unprocessable_entity
    end
  end

  private

  def signup_params
    params.require(:user).permit(:email, :password, :password_confirmation)
  end
end
