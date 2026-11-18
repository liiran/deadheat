# frozen_string_literal: true

require "minitest/autorun"
$LOAD_PATH.unshift File.expand_path("../../lib", __dir__)
require "deadheat/scan"

class ScanTest < Minitest::Test
  def scan(code, indexes: {})
    Deadheat::Scan::Checker.new("app/example.rb", code, indexes).suspects
  end

  def rules(code, **options)
    scan(code, **options).map(&:rule)
  end

  def test_check_then_act_on_the_same_record
    code = <<~RUBY
      class CouponsController
        def redeem
          coupon = Coupon.find_by!(code: params[:code])
          return head(:gone) if coupon.used_at
          coupon.update!(used_at: Time.current)
        end
      end
    RUBY
    suspect = scan(code).first
    assert_equal :check_then_act, suspect.rule
    assert_equal 4, suspect.line
    assert_equal "CouponsController#redeem", suspect.where
    assert_match(/`coupon.used_at` is checked on line 4, then `coupon` is changed \(`update!`\) on line 5/, suspect.message)
  end

  def test_count_then_create
    code = <<~RUBY
      def buy
        event = Event.find(params[:id])
        return if event.tickets.count >= event.capacity
        Ticket.create!(event: event, user: current_user)
      end
    RUBY
    suspect = scan(code).first
    assert_equal :check_then_act, suspect.rule
    assert_match(/is counted on line 3, then a Ticket is created on line 4/, suspect.message)
  end

  def test_a_count_kept_in_a_variable
    code = <<~RUBY
      def claim
        taken = Ticket.where(event: params[:event]).count
        return head(:conflict) if taken >= 1
        Ticket.create!(event: params[:event], seat: taken + 1)
      end
    RUBY
    suspect = scan(code).first
    assert_equal :check_then_act, suspect&.rule
    assert_match(/`taken = Ticket.where\(event: params\[:event\]\).count` is counted on line 3, then a Ticket is created on line 4/, suspect.message)
  end

  def test_exists_then_create_on_the_model
    code = "def tag\n  unless Tagging.exists?(post_id: 1, tag: 'x')\n    Tagging.create!(post_id: 1, tag: 'x')\n  end\nend\n"
    assert_equal [:check_then_act], rules(code)
  end

  def test_hashes_errors_and_nil_checks_are_not_database_reads
    code = <<~RUBY
      def call
        @options.delete(:spoiler) if @options[:sensitive].nil?
        raise UnexpectedMentionsError.new("x", []) unless unexpected_accounts.empty?
        Quote.create!(status: @status) unless @quoted_status.nil?
        name = "a" + "b"
      end
    RUBY
    assert_empty rules(code)
  end

  def test_with_lock_is_safe
    code = <<~RUBY
      def buy
        product = Product.find(params[:id])
        product.with_lock do
          next if product.stock < 1
          product.update!(stock: product.stock - 1)
        end
      end
    RUBY
    assert_empty rules(code)
  end

  def test_a_record_loaded_with_lock_is_safe
    code = <<~RUBY
      def withdraw
        Wallet.transaction do
          wallet = Wallet.lock.find(params[:id])
          return if wallet.balance < 10
          wallet.update!(balance: 0)
        end
      end
    RUBY
    assert_empty rules(code).grep(:check_then_act)
  end

  def test_a_guarded_update_is_safe
    code = <<~RUBY
      def paid
        order = Order.find(params[:id])
        if Order.where(id: order.id, paid_at: nil).update_all(paid_at: Time.current) == 1
          Shipment.create!(order: order)
        end
      end
    RUBY
    assert_empty rules(code)
  end

  def test_math_in_ruby
    assert_equal [:ruby_math], rules("def like\n  post = Post.find(1)\n  post.update!(likes: post.likes + 1)\nend\n")
    assert_equal [:ruby_math], rules("def like\n  @post.likes += 1\n  @post.save!\nend\n")
  end

  def test_database_arithmetic_is_safe
    assert_empty rules("def like\n  Post.update_counters(params[:id], likes: 1)\nend\n")
    assert_empty rules("def like\n  post = Post.find(1)\n  post.increment!(:likes)\nend\n")
  end

  def test_look_then_create_without_an_index
    code = "def follow\n  Follow.find_by(user: u, store: s) || Follow.create!(user: u, store: s)\nend\n"
    suspect = scan(code).first
    assert_equal :look_then_create, suspect.rule
    assert_match(/follows has no unique index on user, store/, suspect.message)
  end

  def test_look_then_create_with_a_unique_index_is_fine
    code = "def follow\n  Follow.find_or_create_by!(user_id: u, store_id: s)\nend\n"
    assert_equal [:look_then_create], rules(code)
    assert_empty rules(code, indexes: { "follows" => [%w[user_id store_id]] })
  end

  def test_uniqueness_validation_without_an_index
    model = "class Subscriber < ApplicationRecord\n  validates :email, presence: true, uniqueness: true\nend\n"
    assert_equal [:unique_without_index], rules(model)
    assert_empty rules(model, indexes: { "subscribers" => [["email"]] })
  end

  def test_scoped_uniqueness_needs_an_index_on_all_columns
    model = "class Follow < ApplicationRecord\n  validates :store_id, uniqueness: { scope: :user_id }\nend\n"
    assert_equal [:unique_without_index], rules(model)
    assert_empty rules(model, indexes: { "follows" => [%w[user_id store_id]] })
  end

  def test_lock_outside_a_transaction
    assert_equal [:lock_outside_transaction], rules("def pay\n  card = Card.find(1)\n  card.lock!\nend\n")
    assert_empty rules("def pay\n  Card.transaction do\n    card = Card.find(1)\n    card.lock!\n  end\nend\n").grep(:lock_outside_transaction)
  end

  def test_unique_indexes_are_read_from_schema_rb
    schema = <<~RUBY
      ActiveRecord::Schema[8.1].define(version: 1) do
        create_table "follows", force: :cascade do |t|
          t.bigint "user_id"
          t.index ["user_id", "store_id"], name: "x", unique: true
          t.index ["store_id"], name: "y"
        end
        add_index "subscribers", ["email"], unique: true
      end
    RUBY
    indexes = Deadheat::Scan::SchemaIndexes.from_schema_rb(schema)
    assert_equal({ "follows" => [%w[user_id store_id]], "subscribers" => [["email"]] }, indexes)
  end
end
