class Post < ApplicationRecord
  belongs_to :author
  has_many :comments, dependent: :delete_all

  validates :title, presence: true, length: { minimum: 3, maximum: 50 }
  validates :rating, numericality: { greater_than_or_equal_to: 0, less_than_or_equal_to: 5 }
  validates :status, inclusion: { in: %w[draft published] }
  validate :body_not_shouting
  validates :body, presence: true, if: :published?

  after_create :log_creation
  before_destroy :protect_locked

  def protect_locked
    throw :abort if title == "Locked"
  end

  def body_not_shouting
    errors.add(:body, "is shouting") if body.length > 3 && body == body.upcase
  end

  def log_creation
    self.views = 0
  end

  scope :published, -> { where(published: true) }
  scope :rated_above, ->(min) { where_not(rating: 0.0).order(rating: :desc).limit(min) }

  def self.visible
    where(published: true).order(rating: :desc)
  end
end
