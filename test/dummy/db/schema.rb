Spinrail::Schema.define do
  create_table :authors do |t|
    t.string :name, null: false
    t.string :email, null: false
    t.timestamps
  end

  create_table :posts do |t|
    t.references :author, null: false
    t.string :title, null: false
    t.text :body, null: false
    t.boolean :published, default: false, null: false
    t.float :rating, null: false
    t.integer :views, default: 0, null: false
    t.string :status, default: "draft", null: false
    t.string :subtitle
    t.integer :priority
    t.integer :kind, default: 0, null: false
    t.timestamps
  end

  create_table :newsletters do |t|
    t.string :email, null: false
  end

  create_table :users do |t|
    t.string :email, null: false
    t.string :password_digest, null: false
    t.timestamps
  end

  create_table :comments do |t|
    t.references :post, null: false
    t.text :body, null: false
    t.timestamps
  end
end
