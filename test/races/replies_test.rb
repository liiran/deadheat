# frozen_string_literal: true

require_relative "../test_helper"

class RepliesRaceTest < DeadheatIntegrationTest
  test "right data with a different reply is reported, but doesn't fail the race" do
    result = race("follow, mixed replies") do |r|
      r.twice { post "/mixed_follow", params: { user_id: 7, target_id: 8 } }
    end
    return assert_sqlite_lock_crash(result) if deferred_sqlite?

    assert result.passed?, result.failure_message
    return if serializes_transactions?

    assert_equal [:different_replies], kinds(result), result.failure_message
  end
end

class ResetRaceTest < DeadheatIntegrationTest
  test "a reset block runs before every run, so state outside the database starts the same" do
    calls = Concurrent::AtomicFixnum.new(0)
    result = race("reset") do |r|
      r.setup { @post = Post.create!(title: "Hi") }
      r.reset { calls.increment }
      r.twice { post "/safe_like/#{@post.id}" }
    end
    assert result.passed?, result.failure_message
    # 2 one-at-a-time orders, a second run of the first order, each actor alone, then every try
    assert_equal 2 + 1 + 1 + result.tries, calls.value
  end
end
