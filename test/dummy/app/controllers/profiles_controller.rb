class ProfilesController < ApplicationController
  def show
    render plain: "profile at " + profile_path
  end
end
