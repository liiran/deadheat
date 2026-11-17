require "test_helper"
require_relative "store_features"

class FixedShopTest < ActionDispatch::IntegrationTest
  def prefix = "/fixed"

  include StoreFeatures
end
