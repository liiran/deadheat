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
