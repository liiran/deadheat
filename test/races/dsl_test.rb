require_relative "../test_helper"

# The Minitest DSL as people write it: a Deadheat::RaceTest with `race` blocks. Each case defines a
# race test class, runs it the way Minitest would, and checks that it passes or fails as it should.
class DslTest < DeadheatIntegrationTest
  def run_race_test(&body)
    klass = Class.new(Deadheat::RaceTest) do
      include Devise::Test::IntegrationHelpers
      def self.name = "TemporaryRaceTest"
      class_eval(&body)
    end
    Minitest::Runnable.runnables.delete(klass) # not part of this suite's own run
    klass.runnable_methods.map { |name| klass.new(name).run }
  end

  def make_team(budget:)
    team = Team.create!(name: "Ops", budget: budget)
    alice = Member.create!(team: team, email: "alice@example.com", password: "password123")
    bob = Member.create!(team: team, email: "bob@example.com", password: "password123")
    [team, alice, bob]
  end

  test "two teammates signed in with Devise overspend a shared budget, and the test fails with the story" do
    test_case = self
    results = run_race_test do
      race "two teammates, one budget" do |r|
        r.setup { @team, @alice, @bob = test_case.make_team(budget: 100) }
        r.as(:alice, sign_in: -> { @alice }) { post "/team/spend", params: { amount: 80 } }
        r.as(:bob, sign_in: -> { @bob }) { post "/team/spend", params: { amount: 80 } }
      end
    end
    result = results.first
    refute result.passed?, "a race test over a buggy endpoint should fail"
    message = result.failures.first.message
    assert_match(/Race: “two teammates, one budget” broke in \d+ of \d+ tries/, message)
    assert_match(/Went below zero: teams #\d+ budget ended at -60/, message)
    assert_match(/alice/, message)
    assert_match(/bob/, message)
    assert_match(/Reproduce: DEADHEAT_SEED=\d+ bin\/rails test .*dsl_test\.rb:\d+/, message)
  end

  test "the fixed endpoint passes, and nothing is left behind" do
    test_case = self
    results = run_race_test do
      race "two teammates, guarded update" do |r|
        r.setup { @team, @alice, @bob = test_case.make_team(budget: 100) }
        r.as(:alice, sign_in: -> { @alice }) { post "/team/safe_spend", params: { amount: 80 } }
        r.as(:bob, sign_in: -> { @bob }) { post "/team/safe_spend", params: { amount: 80 } }
      end
    end
    assert results.first.passed?, -> { results.first.failures.first&.message }
    assert_equal [0, 0], [Team.count, Member.count]
  end

  test "both actors really are signed in as different people" do
    test_case = self
    seen = Concurrent::Array.new
    results = run_race_test do
      race "who am I" do |r|
        r.setup { @team, @alice, @bob = test_case.make_team(budget: 100) }
        r.as(:alice, sign_in: -> { @alice }) { post "/team/safe_spend", params: { amount: 1 }; seen << controller.current_member.email }
        r.as(:bob, sign_in: -> { @bob }) { post "/team/safe_spend", params: { amount: 1 }; seen << controller.current_member.email }
      end
    end
    assert results.first.passed?, -> { results.first.failures.first&.message }
    assert_equal %w[alice@example.com bob@example.com], seen.uniq.sort
    assert_equal seen.count("alice@example.com"), seen.count("bob@example.com"), "every run signs both in"
  end

  test "a sign-in hook is used when there's no helper Dead Heat knows" do
    calls = Concurrent::Array.new
    Deadheat.config.sign_in { |user| calls << user.email; post "/members/sign_in", params: { member: { email: user.email, password: "password123" } } }
    test_case = self
    results = run_race_test do
      race "custom sign in" do |r|
        r.setup { @team, @alice, @bob = test_case.make_team(budget: 100) }
        r.as(:alice, sign_in: -> { @alice }) { post "/team/safe_spend", params: { amount: 80 } }
        r.as(:bob, sign_in: -> { @bob }) { post "/team/safe_spend", params: { amount: 80 } }
      end
    end
    assert results.first.passed?, -> { results.first.failures.first&.message }
    assert_equal %w[alice@example.com bob@example.com], calls.sort
  ensure
    Deadheat.config.instance_variable_set(:@sign_in_hook, nil)
  end
end
