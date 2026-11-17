ActiveRecord::Schema.define do
  create_table :products, force: true do |t|
    t.string :name
    t.integer :stock, null: false, default: 0
  end

  create_table :orders, force: true do |t|
    t.references :product, null: false
    t.string :token
    t.timestamps
  end
  add_foreign_key :orders, :products

  create_table :posts, force: true do |t|
    t.string :title
    t.integer :likes_count, null: false, default: 0
  end

  # No unique index: `validates uniqueness` alone can't stop two signups at once.
  create_table :accounts, force: true do |t|
    t.string :email
    t.timestamps
  end

  create_table :safe_accounts, force: true do |t|
    t.string :email
    t.timestamps
  end
  add_index :safe_accounts, :email, unique: true

  create_table :users, force: true do |t|
    t.string :name
  end

  create_table :follows, force: true do |t|
    t.integer :user_id, null: false
    t.integer :target_id, null: false
  end
  add_index :follows, %i[user_id target_id], unique: true

  create_table :documents, force: true do |t|
    t.string :title
    t.integer :lock_version, null: false, default: 0
  end

  # A join table without a primary key.
  create_table :taggings, id: false, force: true do |t|
    t.integer :post_id
    t.string :tag
  end
end
