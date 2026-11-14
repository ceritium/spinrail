class Comment < ApplicationRecord
  belongs_to :post
  validates :body, presence: true
  before_save :trim, if: :long?

  def long?
    body.length > 10
  end

  def trim
    self.body = body[0, 10]
  end
end
