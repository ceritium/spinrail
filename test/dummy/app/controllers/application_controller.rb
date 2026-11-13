class ApplicationController < Rieles::Controller
  before_action :set_locale
  rescue_from ArgumentError, with: :bad_argument

  private

  def set_locale
    @locale = "en"
  end

  def bad_argument(error)
    render plain: "bad: " + error.message, status: :bad_request
  end
end
