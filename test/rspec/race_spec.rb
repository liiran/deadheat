# frozen_string_literal: true

require_relative "spec_helper"

# Run by test/races/rspec_test.rb, which checks each example's outcome.
RSpec.describe "Likes", type: :race do
  race "BUGGY likes counter" do |r|
    r.setup { @post = Post.create!(title: "Hi") }
    r.twice { post "/like/#{@post.id}" }
  end

  race "FIXED likes counter" do |r|
    r.setup { @post = Post.create!(title: "Hi") }
    r.twice { post "/safe_like/#{@post.id}" }
  end
end

RSpec.describe "Team budget", type: :race do
  let(:team) { Team.create!(name: "Ops", budget: 100) }
  let(:alice) { Member.create!(team: team, email: "alice@example.com", password: "password123") }
  let(:bob) { Member.create!(team: team, email: "bob@example.com", password: "password123") }

  race "BUGGY shared budget" do |r|
    r.as(:alice, sign_in: -> { alice }) { post "/team/spend", params: { amount: 80 } }
    r.as(:bob, sign_in: -> { bob }) { post "/team/spend", params: { amount: 80 } }
  end

  race "FIXED shared budget" do |r|
    r.as(:alice, sign_in: -> { alice }) { post "/team/safe_spend", params: { amount: 80 } }
    r.as(:bob, sign_in: -> { bob }) { post "/team/safe_spend", params: { amount: 80 } }
  end
end

RSpec.describe "Ordinary request specs still roll back", type: :request do
  it "leaves no rows behind" do
    Post.create!(title: "Temporary")
    expect(Post.count).to eq(1)
  end

  it "starts empty, because every race cleaned up" do
    expect([Post.count, Team.count, Member.count]).to eq([0, 0, 0])
  end
end
