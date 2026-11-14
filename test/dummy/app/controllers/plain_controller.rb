class PlainController < ApplicationController
  layout false

  def show
    render "pages/plain"
  end
end
