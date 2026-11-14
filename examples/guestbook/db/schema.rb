Spinrail::Schema.define do
  create_table :entries do |t|
    t.string :name, null: false
    t.text :body, null: false
    t.timestamps
  end
end
