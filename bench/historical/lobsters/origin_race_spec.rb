# frozen_string_literal: true

# Lobsters 8d601f12d (Dec 2024) fixed a race in Domain#find_or_create_origin: two stories from the
# same new origin at once could both try to insert it, and the unique index stopped the second with an
# unhandled ActiveRecord::RecordNotUnique. Lobsters' own draft spec for it is in 7cc3c14ed; this is the
# same situation as a Dead Heat race test. Copied into spec/races/ by bench/historical/run.sh.
require "rails_helper"
require "deadheat/rspec"

RSpec.describe "Origin", type: :race do
  race "two stories from the same new origin" do |r|
    r.setup do
      @domain = Domain.create!(domain: "github.com", selector: '\Ahttps://(github.com/[^/]+).*\z', replacement: '\1')
    end
    2.times { r.run { Domain.find(@domain.id).find_or_create_origin("https://github.com/foo") } }
  end
end
