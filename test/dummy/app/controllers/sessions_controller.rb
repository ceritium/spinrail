class SessionsController < ApplicationController
  def create
    session[:user] = params[:name]
    session[:visits] = 1
    redirect_to "/session", notice: "Welcome " + params[:name]
  end

  def show
    @user = session[:user].to_s
    @visits = session[:visits].to_s
  end

  def destroy
    session.delete(:user)
    flash[:alert] = "Bye"
    redirect_to "/session"
  end

  def now
    flash.now[:notice] = "Only now"
    @user = ""
    @visits = ""
    render :show
  end
end
