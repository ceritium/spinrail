class Entry < ApplicationRecord
  validates :name, presence: true, length: { maximum: 40 }
  validates :body, presence: true, length: { maximum: 500 }

  def excerpt
    body.length > 120 ? body[0, 120] + "…" : body
  end
end
