# frozen_string_literal: true

# A fresh, empty database with the dummy app's schema. Shared by the Minitest and RSpec suites.
db_config = ActiveRecord::Base.connection_db_config
# This empties the database it is pointed at, so it must be a test database.
abort "Refusing to empty “#{db_config.database}”: it isn't named like a test database." unless Deadheat::Preflight.test_name?(db_config.database)
$stdout.then do |out|
  $stdout = File.open(File::NULL, "w") # the database tasks print "already exists" and similar
  ActiveRecord::Tasks::DatabaseTasks.create(db_config)
  ActiveRecord::Tasks::DatabaseTasks.purge(db_config)
ensure
  $stdout = out
end
# Creating a database connects to the server's maintenance database; come back to the test one.
ActiveRecord::Base.establish_connection(db_config)
ActiveRecord::Schema.verbose = false
load File.expand_path("../dummy/db/schema.rb", __dir__)
pool = ActiveRecord::Base.connection_pool
pool.internal_metadata.create_table_and_set_flags("test") if pool.respond_to?(:internal_metadata)
