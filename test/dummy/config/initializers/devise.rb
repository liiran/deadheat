Devise.setup do |config|
  require "devise/orm/active_record"
  config.secret_key = "dummy-devise-secret" * 4
  config.mailer_sender = "shop@example.com"
  config.navigational_formats = []
  config.stretches = 1
end
