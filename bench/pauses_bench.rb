# How often each planted bug shows up per try, with Dead Heat's pauses off and on. The bugs are the
# ones in the gem's own test app (test/dummy), not Corner Store.
#
#   docker compose run --rm -e DB=postgres dev bundle exec ruby bench/pauses_bench.rb
#
# Writes bench/out/pauses-<db>.json and prints a table.
ENV["DEADHEAT_TRIES"] = ENV.fetch("TRIES", "100")
require_relative "../test/test_helper"
require "fileutils"

SCENARIOS = {
  "last item bought twice" => ->(r) { r.setup { @product = Product.create!(name: "Shirt", stock: 1) }; r.twice { post "/buy/#{@product.id}" } },
  "likes counter" => ->(r) { r.setup { @post = Post.create!(title: "Hi") }; r.twice { post "/like/#{@post.id}" } },
  "signup without unique index" => ->(r) { r.twice { post "/signup", params: { email: "sam@example.com" } } },
  "follow hits unique index" => ->(r) { r.twice { post "/follow", params: { user_id: 1, target_id: 2 } } },
  "tag check-then-insert" => ->(r) { r.setup { @post = Post.create!(title: "Hi") }; r.twice { post "/tag", params: { post_id: @post.id, tag: "ruby" } } },
  "service lost update" => ->(r) { r.setup { @post = Post.create!(title: "Hi") }; 2.times { r.run { p = Post.find(@post.id); p.update!(likes_count: p.likes_count + 1) } } }
}.freeze

class PausesBench < DeadheatIntegrationTest
  test "pauses on vs off" do
    db = ActiveRecord::Base.connection.adapter_name
    rows = SCENARIOS.map do |name, definition|
      rates = [false, true].to_h do |pauses|
        Deadheat.config.pauses = pauses
        result = race(name) { |r| instance_exec(r, &definition) }
        [pauses ? :on : :off, (result.broken_tries.to_f / result.tries).round(3)]
      end
      { scenario: name, **rates }
    end
    Deadheat.config.pauses = true
    FileUtils.mkdir_p(File.expand_path("out", __dir__))
    File.write(File.expand_path("out/pauses-#{ENV.fetch('DB', 'sqlite')}.json", __dir__), JSON.pretty_generate(db: db, tries: Integer(ENV["DEADHEAT_TRIES"]), rows: rows))
    puts "\n#{db}, #{ENV['DEADHEAT_TRIES']} tries each"
    rows.each { |row| puts format("  %-30s off %5.1f%%   on %5.1f%%", row[:scenario], row[:off] * 100, row[:on] * 100) }
  end
end
