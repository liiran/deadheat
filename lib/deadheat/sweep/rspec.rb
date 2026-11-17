# Loaded with `rspec --require deadheat/sweep/rspec` by `deadheat sweep`, before rails_helper, so
# this hook wraps everything else.
require "deadheat"

RSpec.configure do |config|
  config.around(:each) do |example|
    next example.run unless Deadheat::Sweep.active?

    if Deadheat::Sweep.mode == "race"
      next example.run unless Deadheat::Sweep.target?(example.id)

      group = example.example_group
      group.uses_transaction(example.metadata[:description]) if group.respond_to?(:uses_transaction)
    end
    Deadheat::Sweep.begin_test(
      id: example.id, file: Deadheat::Sweep.relative(example.metadata[:file_path]), line: example.metadata[:line_number],
      name: example.full_description, context: self, framework: "rspec"
    )
    begin
      example.run
    ensure
      Deadheat::Sweep.end_test
    end
  end
end
