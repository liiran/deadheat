# frozen_string_literal: true

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

  # Deleting a post deletes its comments in the database itself, without a statement of its own.
  create_table :comments, force: true do |t|
    t.references :post, null: false
    t.string :body
  end
  add_foreign_key :comments, :posts, on_delete: :cascade

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

  create_table :teams, force: true do |t|
    t.string :name
    t.integer :budget, null: false, default: 0
  end

  # Devise users (database_authenticatable + trackable).
  create_table :members, force: true do |t|
    t.references :team
    t.string :email, null: false, default: ""
    t.string :encrypted_password, null: false, default: ""
    t.integer :sign_in_count, default: 0, null: false
    t.datetime :current_sign_in_at
    t.datetime :last_sign_in_at
    t.string :current_sign_in_ip
    t.string :last_sign_in_ip
  end
  add_index :members, :email, unique: true

  # A join table without a primary key.
  create_table :taggings, id: false, force: true do |t|
    t.integer :post_id
    t.string :tag
  end
end
