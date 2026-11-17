require_relative "../test_helper"

class SQLTest < Minitest::Test
  SQL = Deadheat::SQL

  def test_kinds
    assert_equal :read, SQL.kind(%(SELECT "products".* FROM "products" WHERE "id" = 1))
    assert_equal :write, SQL.kind(%(INSERT INTO "orders" ("product_id") VALUES (1)))
    assert_equal :write, SQL.kind("/* app:shop */ UPDATE `products` SET `stock` = 0")
    assert_equal :write, SQL.kind(%(DELETE FROM "carts" WHERE "id" = 3))
    assert_equal :transaction, SQL.kind("BEGIN immediate TRANSACTION")
    assert_equal :transaction, SQL.kind("SAVEPOINT active_record_1")
    assert_equal :write, SQL.kind(%(WITH x AS (SELECT 1) INSERT INTO "logs" ("a") SELECT 1))
  end

  def test_tables
    assert_equal ["orders"], SQL.tables(%(INSERT INTO "orders" ("a") VALUES (1)))
    assert_equal ["products"], SQL.tables(%(UPDATE "public"."products" SET "stock" = 0))
    assert_equal %w[orders products], SQL.tables(%(SELECT * FROM "orders" INNER JOIN "products" ON 1=1)).sort
  end

  def test_locking_reads
    assert SQL.locking?("SELECT * FROM products WHERE id = 1 FOR UPDATE")
    assert SQL.locking?("SELECT * FROM products WHERE id = 1 LOCK IN SHARE MODE")
    refute SQL.locking?("SELECT * FROM products")
  end

  def test_readable_fills_in_bound_values
    payload = { sql: %(SELECT "products".* FROM "products" WHERE "id" = $1 AND "name" = $2), type_casted_binds: [7, "Shirt"] }
    assert_equal %(SELECT "products".* FROM "products" WHERE "id" = 7 AND "name" = 'Shirt'), SQL.readable(payload)
    payload = { sql: "SELECT * FROM t WHERE a = ? AND b = ?", type_casted_binds: -> { [1, nil] } }
    assert_equal "SELECT * FROM t WHERE a = 1 AND b = NULL", SQL.readable(payload)
  end

  def test_internal_queries_are_skipped
    assert SQL.internal?(name: "SCHEMA", sql: "SELECT 1")
    assert SQL.internal?(name: "Product Load", cached: true, sql: "SELECT 1")
    refute SQL.internal?(name: "Product Load", sql: "SELECT 1")
  end
end

class EffectsTest < Minitest::Test
  Effects = Deadheat::Effects

  def test_only_whole_numbers_are_masked_as_new_ids
    ids = Set["3", "42"]
    assert_equal "/orders/:new", Effects.mask("/orders/42", ids)
    assert_equal "/~username3", Effects.mask("/~username3", ids)
    assert_equal "/products/7", Effects.mask("/products/7", ids)
  end

  def test_extra_side_effects_and_what_cant_be_undone
    expected = Effects.new(mails: [["a@example.com", "Your order"]], jobs: [["ShipOrderJob", "[]"]])
    mine = Effects.new(mails: [["a@example.com", "Your order"]] * 2, jobs: [["ShipOrderJob", "[]"]] * 2 + [["IndexSearchJob", "[]"]])
    lines, irreversible = mine.extra_over(expected)
    assert irreversible
    assert_includes lines, "1 extra email to a@example.com: “Your order”"
    assert_includes lines, "ShipOrderJob queued 1 more time"
    assert_includes lines, "IndexSearchJob queued 1 more time"

    _, irreversible = Effects.new(jobs: [["IndexSearchJob", "[]"]] * 2).extra_over(Effects.new(jobs: [["IndexSearchJob", "[]"]]))
    refute irreversible, "re-indexing twice can be undone"
  end
end

class PausePlanTest < Minitest::Test
  Step = Deadheat::PausePlan::Step

  def timelines
    steps = [
      Step.new("read:sessions#1", :read, ["sessions"], 0.000),
      Step.new("read:products#1", :read, ["products"], 0.002),
      Step.new("write:orders#1", :write, ["orders"], 0.004),
      Step.new("write:products#1", :write, ["products"], 0.005)
    ]
    [steps, steps]
  end

  def plan(seed = 7)
    Deadheat::PausePlan.new(timelines: timelines, seed: seed)
  end

  def test_the_first_try_has_no_pauses
    schedules, description = plan.for_try(0)
    assert_equal [nil, nil], schedules
    assert_equal "no pauses", description
  end

  def test_the_strategies_take_turns
    descriptions = (1..6).map { |n| plan.for_try(n).last }
    assert_match(/every request waits after its 1st read of products until all have made it/, descriptions[0])
    assert_match(/whichever request makes its 1st read of products first waits \d+ ms/, descriptions[1])
    assert_match(/request \d starts [\d.]+ ms later/, descriptions[2])
    assert_match(/small random pauses/, descriptions[5])
  end

  def test_pauses_target_the_read_that_is_followed_by_a_write_to_the_same_table
    schedules, = plan.for_try(2)
    waited = schedules.first.after_read("read:products#1")
    assert waited&.positive?, "the products read is the gap"
    assert_nil schedules.last.after_read("read:products#1"), "only the first request to get there waits"
  end

  def test_the_same_seed_gives_the_same_pauses
    assert_equal plan(11).for_try(3).last, plan(11).for_try(3).last
    refute_equal plan(11).for_try(3).last, plan(12).for_try(3).last
  end
end
