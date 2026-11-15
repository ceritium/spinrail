class PlainController < ApplicationController
  layout false

  def show
    render "pages/plain"
  end

  def ids
    render plain: params.fetch(:ids, []).join(",")
  end
end
