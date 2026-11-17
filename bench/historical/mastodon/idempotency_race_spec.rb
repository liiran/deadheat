# Mastodon cff25c186 (February 2026) fixed a race "when processing statuses twice with the same
# idempotency key": PostStatusService read the key from Redis, posted, and only then stored the key, so
# a client retrying a post at the same moment published it twice. The check runs in Redis, so this
# race test clears Redis before every run (r.reset); Dead Heat restores the database itself.
require "rails_helper"
require "deadheat/rspec"

RSpec.describe PostStatusService, type: :race do
  race "the same post sent twice with one idempotency key" do |r|
    r.setup { @account = Fabricate(:account) }
    r.reset { Redis.new(url: ENV.fetch("REDIS_URL")).flushdb }
    2.times do |i|
      r.run("post #{i + 1}") do
        PostStatusService.new.call(Account.find(@account.id), text: "Hello, world", idempotency: "the-same-key")
      end
    end
  end
end
