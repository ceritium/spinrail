class BareController < ApplicationController
  layout "bare"

  def show
    render "pages/bare"
  end
end
