# frozen_string_literal: true

# Corner Store: which tools catch the ten planted races, and which raise alarms on the fixed twins?
#
#   docker compose run --rm -e DB=postgres dev ruby bench/tools_bench.rb
#
# It runs, inside the demo app: the app's own tests, database_consistency, active_record_doctor,
# Dead Heat's scan, and Dead Heat's sweep twice (with the tests as they are, at their limits, and
# with ROOM=1, which gives every limit room to spare).
#
# How a planted race counts as caught:
# - the app's tests: a test of that feature fails
# - database_consistency and active_record_doctor: a message that asks for a unique index on one of
#   the feature's tables. That's the one kind of advice either tool gives that is about races.
# - the scan: a suspect in the feature's controller or one of its models
# - the sweep: a race or crash reported on the feature's endpoint
# The same rules, applied to the fixed twin's controller, tables and endpoint, count as an alarm.
#
# Everything each tool printed is saved in bench/out/tools-<db>/, and the scores in
# bench/out/tools-<db>.json.
require "json"
require "open3"
require "fileutils"

DEMO = File.expand_path("../demo", __dir__)
DB = ENV.fetch("DB", "postgres")
OUT = File.expand_path("out/tools-#{DB}", __dir__)
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

def demo(command, name: nil, env: {})
  output, status = Open3.capture2e(ENV_FOR_DEMO.merge(env), "sh", "-c", command, chdir: DEMO)
  File.write(File.join(OUT, "#{name}.txt"), output) if name
  [output, status]
end

def underscore(model)
  model.gsub(/([a-z])([A-Z])/, '\1_\2').downcase
end

def fixed_models(feature)
  feature.models.map { |m| %w[Subscriber Shipment Follow].include?(m) ? "Fixed#{m}" : m }
end

def tables(models)
  models.map { |m| "#{underscore(m)}s" }
end

def score(name)
  caught = FEATURES.map { |f| yield(f, false) }
  alarms = FEATURES.map { |f| yield(f, true) }
  { tool: name, caught: caught.count(true), alarms: alarms.count(true),
    caught_features: FEATURES.zip(caught).select(&:last).map { |f, _| f.name },
    alarm_features: FEATURES.zip(alarms).select(&:last).map { |f, _| f.name } }
end

# Runs a sweep and returns the summary this run wrote. Stops if any fixed twin wasn't really checked:
# "no alarm" must mean "raced and found clean".
def sweep(name, env = {})
  before = Dir[File.join(DEMO, "tmp/deadheat/runs/*/sweep.json")]
  output, status = demo("bin/deadheat sweep --no-tests 2>&1", name: name, env: env)
  fresh = Dir[File.join(DEMO, "tmp/deadheat/runs/*/sweep.json")] - before
  abort "The sweep wrote no summary (exit #{status.exitstatus}):\n#{output}" unless fresh.size == 1

  summary = JSON.parse(File.read(fresh.first))
  FEATURES.each do |f|
    twin = summary["results"].find { |r| r.dig("target", "route") == "/fixed#{f.route}" }
    abort "The fixed twin of “#{f.name}” wasn't checked (#{twin ? twin['status'] : 'no result'})" unless twin && %w[ok protected differs race crash hung].include?(twin["status"])
  end
  summary
end

def sweep_row(label, summary)
  found = summary["results"].select { |r| %w[race crash hung].include?(r["status"]) }
  row = score(label) do |f, fixed|
    route = fixed ? "/fixed#{f.route}" : f.route
    found.any? { |r| r.dig("target", "route") == route }
  end
  row.merge(irreversible: found.count { |r| r["irreversible"] }, coverage: summary["coverage"], seconds: summary["seconds"])
end

FileUtils.mkdir_p(OUT)
demo("bin/rails db:create db:schema:load >/dev/null 2>&1")
rows = []
lock = File.read(File.join(DEMO, "Gemfile.lock"))
versions = %w[database_consistency active_record_doctor rails].to_h { |gem| [gem, lock[/^    #{gem} \(([\d.]+)\)/, 1]] }

# 1. The app's own tests: does a test of the feature fail?
output, status = demo("bin/rails test 2>&1", name: "tests")
tests = output[/(\d+) runs, \d+ assertions, (\d+) failures, (\d+) errors/]
abort "The demo's tests didn't run:\n#{output}" unless tests
failures = output.scan(/^(?:Shop|FixedShop)Test#test_(\w+)/).flatten
rows << score("The app's own tests") { |f, fixed| !fixed && failures.any? { |t| t.tr("_", " ").include?(f.name.downcase.split.first) } }
puts "tests: #{tests} (#{status.success? ? 'all pass' : 'some fail'})"

# 2. database_consistency. Two of its checks ask for a unique index: under a uniqueness validation
#    ("MissingUniqueIndexChecker fail Follow store_id+user_id …") and under a has_one
#    ("MissingIndexChecker fail Order shipment associated model should have a unique index …").
output, = demo("bundle exec database_consistency 2>&1", name: "database_consistency")
lines = output.lines.grep(/ fail /)
flagged = lines.filter_map do |line|
  match = line.match(/Missing(?:Unique)?IndexChecker fail (\w+) (\S+) .*unique index/) or next
  line.include?("associated model") ? "#{match[2]}s" : "#{underscore(match[1])}s"
end
rows << score("database_consistency #{versions['database_consistency']}") do |f, fixed|
  (tables(fixed ? fixed_models(f) : f.models) & flagged).any?
end.merge(messages: lines.size, about_races: flagged)

# 3. active_record_doctor: "add a unique index on follows(user_id, store_id) - …".
output, = demo("bundle exec rake active_record_doctor 2>&1", name: "active_record_doctor")
lines = output.lines.reject { |l| l.strip.empty? || l.start_with?("rake ") }
flagged = lines.filter_map { |line| line[/\Aadd a unique (?:expression )?index on (\w+)\(/, 1] }
rows << score("active_record_doctor #{versions['active_record_doctor']}") do |f, fixed|
  (tables(fixed ? fixed_models(f) : f.models) & flagged).any?
end.merge(messages: lines.size, about_races: flagged)

# 4. Dead Heat scan: a suspect in the feature's controller or one of its models.
FileUtils.rm_f(File.join(DEMO, "tmp/deadheat/scan.json"))
_, status = demo("bin/deadheat scan 2>&1", name: "scan")
abort "The scan failed" unless status.success? && File.exist?(File.join(DEMO, "tmp/deadheat/scan.json"))
suspects = JSON.parse(File.read(File.join(DEMO, "tmp/deadheat/scan.json")))["suspects"]
rows << score("Dead Heat scan") do |f, fixed|
  folder = fixed ? "fixed" : "shop"
  models = fixed ? fixed_models(f) : f.models
  suspects.any? { |s| s["file"] == "app/controllers/#{folder}/#{f.controller}_controller.rb" || models.any? { |m| s["file"] == "app/models/#{underscore(m)}.rb" } }
end.merge(messages: suspects.size)

# 5. Dead Heat sweep, with the tests as they are (each limit feature is tested at its limit) …
rows << sweep_row("Dead Heat sweep", sweep("sweep"))
# … and with room to spare in every limit (5 in stock, 100 seats, a small withdrawal, 5 invite uses).
rows << sweep_row("Dead Heat sweep, tests with room to spare", sweep("sweep-room", "ROOM" => "1"))

File.write(File.expand_path("out/tools-#{DB}.json", __dir__), JSON.pretty_generate(db: DB, versions: versions, tests: tests, rows: rows))

puts "\nCorner Store on #{DB}: ten planted races, ten fixed twins\n\n"
puts "| Tool | Planted races caught | Alarms on fixed twins |"
puts "| --- | --- | --- |"
rows.each { |r| puts "| #{r[:tool]} | #{r[:caught]} of 10 | #{r[:alarms]} of 10 |" }
puts
rows.each { |r| puts "#{r[:tool]}: #{r[:caught_features].join(', ')}#{" | ALARMS: #{r[:alarm_features].join(', ')}" if r[:alarm_features].any?}" }
rows.select { |r| r[:coverage] }.each do |r|
  puts "#{r[:tool]}: #{r[:irreversible]} irreversible; #{r.dig(:coverage, 'checked')} of #{r.dig(:coverage, 'write_endpoints')} write endpoints; #{r[:seconds]} s"
end
