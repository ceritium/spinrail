class Author < ApplicationRecord
  has_many :posts, dependent: :destroy

  validates :name, presence: true
  validates :email, format: { with: /\A[^@\s]+@[^@\s]+\z/ }, uniqueness: true

  before_validation :normalize_email

  def normalize_email
    self.email = email.strip.downcase
  end
end
