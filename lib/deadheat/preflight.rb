module Deadheat
  # Checks, before anything runs, that racing is safe here and that the results will mean something.
  # Every refusal says what to change.
  module Preflight
    module_function

    def check!(actors:)
      refuse!("Dead Heat only runs in the test environment (RAILS_ENV is #{Rails.env}). It writes to and restores database tables.") unless Rails.env.test?

      connection = ActiveRecord::Base.respond_to?(:lease_connection) ? ActiveRecord::Base.lease_connection : ActiveRecord::Base.connection
      check_database_name!(connection)
      check_environment_record!
      check_pool!(actors)
      check_reloading!
      check_concurrency!
      check_transaction!(connection)
      eager_load!
      connection
    end

    def refuse!(message)
      raise Refused, message
    end

    def check_database_name!(connection)
      config = ActiveRecord::Base.connection_db_config
      name = config.database.to_s
      if name == ":memory:" || name.include?("mode=memory")
        refuse!("The test database is an in-memory SQLite database, which each connection sees separately, so racing requests wouldn't share data. Use a file, like storage/test.sqlite3.")
      end
      allowed = ENV["DEADHEAT_ALLOW_DATABASE"]
      return if name.match?(/test/i) || (allowed && allowed == name)

      refuse!("The database “#{name}” doesn't look like a test database. Dead Heat writes to and restores tables, so it only runs on a database whose name contains “test”. If this one really is a throwaway test database, set DEADHEAT_ALLOW_DATABASE=#{name}.")
    end

    def check_environment_record!
      pool = ActiveRecord::Base.connection_pool
      metadata = pool.respond_to?(:internal_metadata) ? pool.internal_metadata : ActiveRecord::Base.connection.internal_metadata
      recorded = metadata[:environment]
      return if recorded.nil? || recorded == "test"

      refuse!("This database was set up for the “#{recorded}” environment (its ar_internal_metadata says so). Dead Heat only runs on a test database.")
    rescue ActiveRecord::ActiveRecordError, NoMethodError
      nil
    end

    def check_pool!(actors)
      size = ActiveRecord::Base.connection_pool.size
      return if size >= actors + 1

      refuse!("The test database's connection pool holds #{size} connections, but #{actors} racing requests plus the test itself need #{actors + 1}. Raise `pool:` in config/database.yml for the test environment.")
    end

    def check_reloading!
      config = Rails.application.config
      reloading = config.respond_to?(:reloading_enabled?) ? config.reloading_enabled? : !config.cache_classes
      return unless reloading

      refuse!("Code reloading is on in the test environment, which makes threads wait for each other. Set `config.enable_reloading = false` in config/environments/test.rb.")
    end

    def check_concurrency!
      locked = Rails.application.config.allow_concurrency == false ||
               (defined?(Rack::Lock) && Rails.application.middleware.middlewares.any? { |m| m.klass == Rack::Lock })
      return unless locked

      refuse!("The app only lets one request run at a time in tests (`allow_concurrency` is false, so Rack::Lock is in the middleware). Racing requests would just queue. Remove `config.allow_concurrency = false`.")
    end

    def check_transaction!(connection)
      return unless connection.transaction_open?

      refuse!("This test runs inside a database transaction (transactional tests, DatabaseCleaner's :transaction strategy, or `before_all`). Racing requests use their own connections and can't see data that hasn't been committed. Race tests turn transactional tests off; if you use DatabaseCleaner or TestProf, exclude race tests from them.")
    end

    def eager_load!
      return if @eager_loaded

      Rails.application.eager_load! unless Rails.application.config.eager_load
      @eager_loaded = true
    end
  end
end
