# Corner Store: which tools catch the ten planted races, and which raise alarms on the fixed twins?
#
#   docker compose run --rm -e DB=postgres dev ruby bench/tools_bench.rb
#
# It runs, inside the demo app: the app's own tests, database_consistency, active_record_doctor,
# Dead Heat's scan and Dead Heat's sweep. Each planted race counts as caught when the tool points at
# its code, its endpoint, or one of its tables in a way that's about the race. Writes
# bench/out/tools-<db>.json and prints a Markdown table.
require "json"
require "open3"
require "fileutils"

DEMO = File.expand_path("../demo", __dir__)
DB = ENV.fetch("DB", "postgres")
ENV_FOR_DEMO = { "DB" => DB, "BUNDLE_GEMFILE" => File.join(DEMO, "Gemfile"), "RUBYOPT" => nil, "BUNDLE_BIN_PATH" => nil }.freeze

Feature = Struct.new(:name, :route, :controller, :models, keyword_init: true)
FEATURES = [
  Feature.new(name: "Last item bought twice", route: "/products/:product_id/buy", controller: "checkouts", models: %w[Product Order]),
  Feature.new(name: "One-use coupon used twice", route: "/coupons/:code/redeem", controller: "coupons", models: %w[Coupon Discount]),
  Feature.new(name: "Gift card overspent", route: "/gift_cards/:code/spend", controller: "gift_cards", models: %w[GiftCard GiftCardCharge]),
  Feature.new(name: "Newsletter signup twice", route: "/newsletter", controller: "subscribers", models: %w[Subscriber]),
  Feature.new(name: "Helpful vote lost", route: "/reviews/:id/helpful", controller: "reviews", models: %w[Review]),
  Feature.new(name: "Paid webhook ships twice", route: "/webhooks/order_paid", controller: "webhooks", models: %w[Order Shipment]),
  Feature.new(name: "Store followed twice", route: "/stores/:store_id/follow", controller: "follows", models: %w[Follow]),
  Feature.new(name: "Event oversold", route: "/events/:event_id/tickets", controller: "tickets", models: %w[Event Ticket]),
  Feature.new(name: "Wallet overdrawn", route: "/wallet/withdraw", controller: "wallets", models: %w[Wallet Withdrawal]),
  Feature.new(name: "Invite used twice", route: "/invites/:code/accept", controller: "invites", models: %w[Invite Membership])
].freeze

def demo(command)
  output, status = Open3.capture2e(ENV_FOR_DEMO, "sh", "-c", command, chdir: DEMO)
  [output, status]
end

def fixed_models(feature)
  feature.models.map { |m| %w[Subscriber Shipment Follow].include?(m) ? "Fixed#{m}" : m }
end

def tables(models)
  models.map { |m| m.gsub(/([a-z])([A-Z])/, '\1_\2').downcase + "s" }
end

def score(name, messages)
  caught = FEATURES.map { |f| yield(f, false) }
  alarms = FEATURES.map { |f| yield(f, true) }
  { tool: name, caught: caught.count(true), alarms: alarms.count(true), messages: messages,
    caught_features: FEATURES.zip(caught).select(&:last).map { |f, _| f.name } }
end

demo("bin/rails db:create db:schema:load >/dev/null 2>&1")
rows = []

# 1. The app's own tests: does any test fail?
output, status = demo("bin/rails test test/integration 2>&1")
failures = output.scan(/^(?:Shop|FixedShop)Test#test_(\w+)/).flatten
rows << score("The app's own tests", failures.size) { |f, fixed| failures.any? { |t| t.tr("_", " ").include?(f.name.downcase.split.first) } && !fixed }
puts "tests: #{status.success? ? 'all pass' : 'some fail'}"

# 2. database_consistency: only uniqueness checks are about races; the rest is listed but not counted.
output, = demo("bundle exec database_consistency 2>&1")
lines = output.lines.grep(/ fail /)
unique = lines.grep(/MissingUniqueIndexChecker/) # "the model validates uniqueness but has no unique index"
rows << score("database_consistency", lines.size) do |f, fixed|
  models = fixed ? fixed_models(f) : f.models
  unique.any? { |l| models.any? { |m| l.match?(/ #{m} /) } }
end

# 3. active_record_doctor: unique index advice is about races.
output, = demo("bundle exec rake active_record_doctor 2>&1")
lines = output.lines.reject { |l| l.strip.empty? || l.start_with?("rake ") }
unique = lines.grep(/unique/i)
rows << score("active_record_doctor", lines.size) do |f, fixed|
  names = tables(fixed ? fixed_models(f) : f.models)
  unique.any? { |l| names.any? { |t| l.match?(/\b#{t}\(/) } }
end

# 4. Dead Heat scan: a suspect in the feature's controller or model.
demo("bin/deadheat scan >/dev/null 2>&1")
suspects = JSON.parse(File.read(File.join(DEMO, "tmp/deadheat/scan.json")))["suspects"]
rows << score("Dead Heat scan", suspects.size) do |f, fixed|
  folder = fixed ? "fixed" : "shop"
  models = fixed ? fixed_models(f) : f.models
  suspects.any? { |s| s["file"] == "app/controllers/#{folder}/#{f.controller}_controller.rb" || models.any? { |m| s["file"] == "app/models/#{m.gsub(/([a-z])([A-Z])/, '\1_\2').downcase}.rb" } }
end

# 5. Dead Heat sweep: a race on the feature's endpoint.
output, = demo("bin/deadheat sweep --no-tests 2>&1")
latest = Dir[File.join(DEMO, "tmp/deadheat/runs/*/sweep.json")].max_by { |p| File.mtime(p) }
sweep = JSON.parse(File.read(latest))
races = sweep["results"].select { |r| %w[race crash].include?(r["status"]) }
rows << score("Dead Heat sweep", races.size) do |f, fixed|
  route = fixed ? "/fixed#{f.route}" : f.route
  races.any? { |r| r.dig("target", "route") == route }
end
irreversible = races.count { |r| r["irreversible"] }

FileUtils.mkdir_p(File.expand_path("out", __dir__))
File.write(File.expand_path("out/tools-#{DB}.json", __dir__), JSON.pretty_generate(db: DB, rows: rows, irreversible: irreversible, coverage: sweep["coverage"], seconds: sweep["seconds"]))

puts "\nCorner Store on #{DB}: ten planted races, ten fixed twins\n\n"
puts "| Tool | Planted races caught | Alarms on fixed twins | Messages printed |"
puts "| --- | --- | --- | --- |"
rows.each { |r| puts "| #{r[:tool]} | #{r[:caught]} of 10 | #{r[:alarms]} of 10 | #{r[:messages]} |" }
puts "\nSweep: #{irreversible} of the races found had side effects that can't be undone; coverage #{sweep.dig('coverage', 'checked')}/#{sweep.dig('coverage', 'write_endpoints')} write endpoints; #{sweep['seconds']} s."
rows.each { |r| puts "#{r[:tool]}: #{r[:caught_features].join(', ')}" }
