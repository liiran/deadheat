require "test_helper"
require_relative "store_features"

class ShopTest < ActionDispatch::IntegrationTest
  def prefix = ""

  include StoreFeatures
end
