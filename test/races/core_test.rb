require_relative "../test_helper"

# Every planted bug in the dummy app must be found, every fixed twin must pass, on every database.
class CoreRaceTest < DeadheatIntegrationTest
  test "two purchases of the last item make two orders" do
    result = race("last item") do |r|
      r.setup { @product = Product.create!(name: "Shirt", stock: 1) }
      r.twice { post "/buy/#{@product.id}" }
    end
    refute result.passed?
    finding = result.races.first
    assert_equal :made_twice, finding.kind, result.failure_message
    assert_match(/2 new orders/, finding.title)
    assert finding.irreversible, "a second confirmation email can't be unsent"
    assert_match(/products/, finding.why)
    assert result.broken_tries >= result.tries / 2, "found in only #{result.broken_tries} of #{result.tries} tries"
  end

  test "the locked version of the purchase passes" do
    result = race("last item, locked") do |r|
      r.setup { @product = Product.create!(name: "Shirt", stock: 1) }
      r.twice { post "/safe_buy/#{@product.id}" }
    end
    return assert_sqlite_lock_crash(result) if deferred_sqlite?
    assert_no_findings(result)
  end

  test "two likes at once lose one" do
    result = race("likes") do |r|
      r.setup { @post = Post.create!(title: "Hi") }
      r.twice { post "/like/#{@post.id}" }
    end
    assert_equal [:lost_update], kinds(result), result.failure_message
    assert_match(/likes_count went 0 → 1, one at a time 0 → 2/, result.races.first.title)
  end

  test "likes counted by the database pass" do
    result = race("likes, update_counters") do |r|
      r.setup { @post = Post.create!(title: "Hi") }
      r.twice { post "/safe_like/#{@post.id}" }
    end
    assert_no_findings(result)
  end

  test "a uniqueness validation without an index lets two signups through" do
    result = race("signup") do |r|
      r.twice { post "/signup", params: { email: "sam@example.com" } }
    end
    return assert_sqlite_lock_crash(result) if deferred_sqlite?
    return assert_no_findings(result) if serializes_transactions?

    assert_equal :duplicate_rule, result.races.first&.kind, result.failure_message
    assert_match(/2 accounts with the same email “sam@example.com”/, result.races.first.title)
  end

  test "a unique index with the conflict handled passes" do
    result = race("signup, unique index") do |r|
      r.twice { post "/safe_signup", params: { email: "sam@example.com" } }
    end
    return assert_sqlite_lock_crash(result) if deferred_sqlite?
    assert_no_findings(result)
  end

  test "an unhandled unique index error is a crash, not bad data" do
    result = race("follow") do |r|
      r.twice { post "/follow", params: { user_id: 1, target_id: 2 } }
    end
    return assert_sqlite_lock_crash(result) if deferred_sqlite?
    return assert_no_findings(result) if serializes_transactions?

    assert_equal [:crash], kinds(result), result.failure_message
    assert_match(/RecordNotUnique/, result.crashes.first.title)
    assert_match(/RecordNotUnique/, result.crashes.first.fixes.first)
  end

  test "create_or_find_by passes" do
    result = race("follow, create_or_find_by") do |r|
      r.twice { post "/safe_follow", params: { user_id: 1, target_id: 2 } }
    end
    return assert_sqlite_lock_crash(result) if deferred_sqlite?
    assert_no_findings(result)
  end

  test "optimistic locking counts as protected, and the race test passes" do
    result = race("rename") do |r|
      r.setup { @document = Document.create!(title: "Draft") }
      r.as(:alice) { patch "/documents/#{@document.id}", params: { title: "Alice's" } }
      r.as(:bob) { patch "/documents/#{@document.id}", params: { title: "Bob's" } }
    end
    assert result.passed?, result.failure_message
    assert_includes kinds(result), :protected, result.failure_message
  end

  test "a check-then-insert on a table without a primary key is found" do
    result = race("tag") do |r|
      r.setup { @post = Post.create!(title: "Hi") }
      r.twice { post "/tag", params: { post_id: @post.id, tag: "ruby" } }
    end
    assert_equal :made_twice, result.races.first&.kind, result.failure_message
  end

  test "a custom check catches what the comparison already sees, and says which rule broke" do
    result = race("checked") do |r|
      r.setup { @product = Product.create!(name: "Mug", stock: 1) }
      r.twice { post "/buy/#{@product.id}" }
      r.check("never sell more than we have") { Order.where(product_id: @product.id).count <= 1 }
    end
    assert_equal :check, result.races.first&.kind, result.failure_message
  end

  test "jobs and service code can race too" do
    result = race("service") do |r|
      r.setup { @post = Post.create!(title: "Hi") }
      2.times { r.run { post = Post.find(@post.id); post.update!(likes_count: post.likes_count + 1) } }
    end
    assert_equal [:lost_update], kinds(result), result.failure_message
  end

  test "the database is left exactly as it was" do
    Product.create!(name: "Before", stock: 3)
    before = [Product.count, Order.count, Product.pluck(:stock)]
    race("cleanup") do |r|
      r.setup { @product = Product.create!(name: "Shirt", stock: 1) }
      r.twice { post "/buy/#{@product.id}" }
    end
    assert_equal before, [Product.count, Order.count, Product.pluck(:stock)]
  ensure
    Product.where(name: "Before").delete_all
  end
end
