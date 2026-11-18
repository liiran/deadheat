# Prints what every try of a race test did, from the result file Dead Heat saved. A passing race test
# prints nothing itself, so this is how "no race in N tries" is read:
#
#   ruby bench/historical/summary.rb tmp/deadheat
#
# - ok: the try matched a one-at-a-time run exactly
# - differs: the data matched, but the replies matched no one-at-a-time run (not counted as a race)
# - protected: one request was turned away (a lock or a stale-object error) and the data was right
# - race / crash / hung: the try broke
require "json"

Dir[File.join(ARGV.fetch(0), "runs/*/*.json")].each do |path|
  result = JSON.parse(File.read(path))
  next unless result["counts"]

  puts "   tries: #{result['tries']}  #{result['counts'].map { |status, n| "#{status}: #{n}" }.join(', ')}"
  puts "   one at a time, the replies are: #{result.dig('expected', 'replies').inspect}"
  result["warnings"].to_a.each { |warning| puts "   note: #{warning}" }
end
