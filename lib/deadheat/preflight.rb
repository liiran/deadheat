module Deadheat
  # Checks, before anything runs, that racing is safe here and that the results will mean something.
  # Every refusal says what to change.
  module Preflight
    module_function

    def check!
      connection = database!
      check_deliveries!
      check_reloading!
      check_concurrency!
      check_transaction!(connection)
      eager_load!
      connection
    end

    # The checks that keep Dead Heat away from anything but a test database. Everything that deletes
    # rows (restoring a snapshot) or lets a test's data be committed calls this first.
    def database!
      refuse!("Dead Heat only runs in the test environment (RAILS_ENV is #{Rails.env}). It writes to and restores database tables.") unless Rails.env.test?

      connection = ActiveRecord::Base.respond_to?(:lease_connection) ? ActiveRecord::Base.lease_connection : ActiveRecord::Base.connection
      config = ActiveRecord::Base.connection_db_config
      return connection if @checked.equal?(config)

      check_database_name!(config)
      check_environment_record!
      @checked = config
      connection
    end

    def refuse!(message)
      raise Refused, message
    end

    def check_database_name!(config)
      name = config.database.to_s
      if name == ":memory:" || name.include?("mode=memory")
        refuse!("The test database is an in-memory SQLite database, which each connection sees separately, so racing requests wouldn't share data. Use a file, like storage/test.sqlite3.")
      end
      allowed = ENV["DEADHEAT_ALLOW_DATABASE"]
      return if test_name?(name) || (allowed && allowed == name)

      refuse!("The database “#{name}” doesn't look like a test database. Dead Heat writes to and restores tables, so it only runs on a database whose name has “test” in it as a word (app_test, test.sqlite3) and no “production”, “staging” or “live”. If this one really is a throwaway test database, set DEADHEAT_ALLOW_DATABASE=#{name}.")
    end

    # "test" as a word of its own: app_test, app_test-2, storage/test.sqlite3, testing_db, MyAppTest.
    # Not a word that happens to contain it (contest, latest, attestations), and never a name that
    # also says production, staging or live (test_scores_production).
    # For a SQLite file only the file's own name counts, not the folders above it.
    def test_name?(name)
      base = File.basename(name.to_s)
      return false if base.match?(/(?<![a-z])(?:production|prod|staging|live)(?![a-z])/i)

      base.match?(/(?<![a-z])test(?:s|ing)?(?![a-z])/i) || base.match?(/(?<=[a-z])Test(?![a-z])/)
    end

    # Rails writes the environment a database was set up for into ar_internal_metadata. One set up
    # for another environment is refused; so is one whose record can't be read.
    def check_environment_record!
      pool = ActiveRecord::Base.connection_pool
      metadata = pool.respond_to?(:internal_metadata) ? pool.internal_metadata : ActiveRecord::Base.connection.internal_metadata
      recorded = metadata.table_exists? ? metadata[:environment] : nil
      return if recorded.nil? || recorded == "test"

      refuse!("This database was set up for the “#{recorded}” environment (its ar_internal_metadata says so). Dead Heat only runs on a test database.")
    rescue ActiveRecord::ActiveRecordError, NoMethodError => e
      refuse!("Dead Heat couldn't read which environment this database was set up for (#{e.class}: #{e.message.to_s[0, 80]}), so it won't write to it.")
    end

    # Every raced request runs about 25 times. With real email delivery that's 25 real emails.
    def check_deliveries!
      return unless defined?(ActionMailer::Base)
      return if ActionMailer::Base.delivery_method == :test || !ActionMailer::Base.perform_deliveries
      return if ENV["DEADHEAT_ALLOW_REAL_EMAIL"] == "1"

      refuse!("Email is really delivered in the test environment here (delivery_method is :#{ActionMailer::Base.delivery_method}), and Dead Heat runs each raced request about 25 times. Set `config.action_mailer.delivery_method = :test` in config/environments/test.rb. If the mail really goes nowhere (a local catcher), set DEADHEAT_ALLOW_REAL_EMAIL=1.")
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
