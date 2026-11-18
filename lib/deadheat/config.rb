# frozen_string_literal: true

module Deadheat
  # Settings, all optional. Set them in test/races/race_helper.rb (or spec/races/race_helper.rb):
  #
  #   Deadheat.configure do |c|
  #     c.tries = 30
  #     c.ignore_columns "users.last_seen_at", "carts.token"
  #     c.sign_in { |user| post login_path, params: { email: user.email, password: "secret" } }
  #   end
  class Config
    # Tables Rails or common gems keep for themselves. They're still restored between tries, but a
    # difference in them isn't a race in the app.
    DEFAULT_IGNORED_TABLES = %w[
      schema_migrations ar_internal_metadata sessions
      active_storage_blobs active_storage_attachments active_storage_variant_records
      versions audits
    ].freeze
    IGNORED_TABLE_PREFIXES = %w[solid_queue_ solid_cache_ solid_cable_ good_job].freeze

    # Columns that change on every sign-in or request rather than because of what a request did.
    DEFAULT_IGNORED_COLUMNS = %w[
      sign_in_count current_sign_in_at last_sign_in_at current_sign_in_ip last_sign_in_ip
      last_seen_at last_active_at last_request_at
    ].freeze

    # How many times the actions are run together. Each try uses different pauses.
    attr_accessor :tries
    # The longest single pause, in seconds.
    attr_accessor :max_pause
    # A try that takes longer than this (seconds) is stopped and reported as hung.
    attr_accessor :try_timeout
    # How long a racing request waits for a row lock before the database gives up (seconds).
    attr_accessor :lock_timeout
    # Picks the pauses. The same seed replays the same pauses. DEADHEAT_SEED overrides it.
    attr_accessor :seed
    # Where results are written for `deadheat report`.
    attr_accessor :results_dir
    # Pauses on (the default) or off. Off is only useful for measuring what the pauses add.
    attr_accessor :pauses

    attr_reader :ignored_tables, :ignored_columns, :sign_in_hook

    def initialize
      @tries = Integer(ENV.fetch("DEADHEAT_TRIES", 20))
      @max_pause = 0.25
      @try_timeout = 15.0
      @lock_timeout = 5
      @seed = ENV["DEADHEAT_SEED"]&.to_i
      @results_dir = ENV["DEADHEAT_RESULTS_DIR"]
      @pauses = ENV["DEADHEAT_PAUSES"] != "0"
      @ignored_tables = DEFAULT_IGNORED_TABLES.dup
      @ignored_columns = { "*" => DEFAULT_IGNORED_COLUMNS.dup }
      @sign_in_hook = nil
      @reset_hooks = []
    end

    # ignore_tables "visits", "ahoy_events"
    def ignore_tables(*names)
      @ignored_tables.concat(names.flatten.map(&:to_s))
    end

    # ignore_columns "users.last_seen_at", "tokens.value", "*.lock_version"
    def ignore_columns(*names)
      names.flatten.each do |name|
        table, column = name.to_s.split(".", 2)
        raise ArgumentError, "Write columns as \"table.column\", like \"users.last_seen_at\"" unless column
        (@ignored_columns[table] ||= []) << column
      end
    end

    # State outside the database to put back before every run, for every race and the sweep:
    #   c.reset { Rails.cache.clear }
    #   c.reset { Redis.new.flushdb }
    def reset(&block)
      @reset_hooks << block
    end

    def reset_hooks
      @reset_hooks.dup
    end

    # How a test signs a user in. The block runs inside that user's own session, like a test body:
    #   c.sign_in { |user| post login_path, params: { email: user.email, password: "secret" } }
    def sign_in(&block)
      @sign_in_hook = block
    end

    def ignored_table?(table)
      @ignored_tables.include?(table) || IGNORED_TABLE_PREFIXES.any? { |prefix| table.start_with?(prefix) }
    end

    def ignored_column?(table, column)
      @ignored_columns.fetch("*", []).include?(column) || @ignored_columns.fetch(table, []).include?(column)
    end

    def seed_for_run
      seed || Random.new_seed % 100_000
    end

    def results_path
      results_dir || (defined?(Rails) && Rails.respond_to?(:root) && Rails.root ? Rails.root.join("tmp/deadheat").to_s : File.expand_path("tmp/deadheat"))
    end
  end
end
