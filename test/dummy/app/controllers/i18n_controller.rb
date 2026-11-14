class I18nController < ApplicationController
  before_action :set_locale

  def show
    post = Post.new(title: "x", rating: 1.0)
    post.valid?
    @errors = post.errors.full_messages.first(2).join(" / ")
    @flash_text = t(".saved")
    @money = 1234567.5
  end

  private

  def set_locale
    I18n.locale = params[:locale].empty? ? locale_from_accept_language : params[:locale]
  end
end
