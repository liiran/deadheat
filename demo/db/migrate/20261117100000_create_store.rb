class CreateStore < ActiveRecord::Migration[8.1]
  def change
    create_table :products do |t|
      t.string :name, null: false
      t.integer :price_cents, null: false, default: 0
      t.integer :stock, null: false, default: 0
      t.timestamps
    end

    create_table :orders do |t|
      t.references :user, null: false, foreign_key: true
      t.references :product, null: false, foreign_key: true
      t.integer :total_cents, null: false, default: 0
      t.datetime :paid_at
      t.timestamps
    end

    create_table :coupons do |t|
      t.string :code, null: false, index: { unique: true }
      t.integer :percent_off, null: false
      t.datetime :used_at
      t.timestamps
    end

    create_table :discounts do |t|
      t.references :user, null: false, foreign_key: true
      t.references :coupon, null: false, foreign_key: true
      t.integer :percent_off, null: false
      t.timestamps
    end

    create_table :gift_cards do |t|
      t.string :code, null: false, index: { unique: true }
      t.integer :balance_cents, null: false, default: 0
      t.timestamps
    end

    create_table :gift_card_charges do |t|
      t.references :gift_card, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.integer :amount_cents, null: false
      t.timestamps
    end

    # Newsletter signups. The model validates the email is unique, but there's no unique index.
    create_table :subscribers do |t|
      t.string :email, null: false
      t.timestamps
    end

    create_table :fixed_subscribers do |t|
      t.string :email, null: false, index: { unique: true }
      t.timestamps
    end

    create_table :reviews do |t|
      t.references :product, null: false, foreign_key: true
      t.string :body, null: false
      t.integer :helpful_count, null: false, default: 0
      t.timestamps
    end

    create_table :shipments do |t|
      t.references :order, null: false, foreign_key: true
      t.timestamps
    end

    create_table :fixed_shipments do |t|
      t.references :order, null: false, foreign_key: true, index: { unique: true }
      t.timestamps
    end

    create_table :stores do |t|
      t.string :name, null: false
      t.timestamps
    end

    create_table :follows do |t|
      t.references :user, null: false, foreign_key: true
      t.references :store, null: false, foreign_key: true
      t.timestamps
    end

    create_table :fixed_follows do |t|
      t.references :user, null: false, foreign_key: true
      t.references :store, null: false, foreign_key: true
      t.timestamps
    end
    add_index :fixed_follows, %i[user_id store_id], unique: true

    create_table :events do |t|
      t.string :name, null: false
      t.integer :capacity, null: false
      t.timestamps
    end

    create_table :tickets do |t|
      t.references :event, null: false, foreign_key: true
      t.references :user, null: false, foreign_key: true
      t.timestamps
    end

    create_table :wallets do |t|
      t.references :user, null: false, foreign_key: true
      t.integer :balance_cents, null: false, default: 0
      t.timestamps
    end

    create_table :withdrawals do |t|
      t.references :wallet, null: false, foreign_key: true
      t.integer :amount_cents, null: false
      t.timestamps
    end

    create_table :invites do |t|
      t.string :code, null: false, index: { unique: true }
      t.integer :max_uses, null: false, default: 1
      t.integer :uses, null: false, default: 0
      t.timestamps
    end

    create_table :memberships do |t|
      t.references :user, null: false, foreign_key: true
      t.references :invite, null: false, foreign_key: true
      t.timestamps
    end
  end
end
