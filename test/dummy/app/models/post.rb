class Post < ApplicationRecord
  belongs_to :author
  has_many :comments, dependent: :delete_all

  validates :title, presence: true, length: { minimum: 3, maximum: 50 }
  validates :rating, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 5 }
  validates :status, inclusion: { in: %w[draft published] }
  validate :body_not_shouting

  after_create :log_creation

  def body_not_shouting
    errors.add(:body, "is shouting") if body.length > 3 && body == body.upcase
  end

  def log_creation
    self.views = 0
  end

  def self.visible
    where(published: true).order(rating: :desc)
  end
end
