class Newsletter < ApplicationRecord
  validates :email, presence: true, confirmation: true
  validates :terms_of_service, acceptance: true
end
