Rieles::Schema.define do
  create_table :authors do |t|
    t.string :name
    t.string :email
    t.timestamps
  end

  create_table :posts do |t|
    t.references :author
    t.string :title
    t.text :body
    t.boolean :published, default: false
    t.float :rating
    t.integer :views, default: 0
    t.string :status, default: "draft"
    t.string :subtitle, null: true
    t.integer :priority, null: true
    t.integer :kind, default: 0
    t.timestamps
  end

  create_table :newsletters do |t|
    t.string :email
  end

  create_table :users do |t|
    t.string :email
    t.string :password_digest
    t.timestamps
  end

  create_table :comments do |t|
    t.references :post
    t.text :body
    t.timestamps
  end
end
