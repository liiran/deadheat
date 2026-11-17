module Deadheat
  # Runs one race from start to finish:
  #
  # 1. setup, then sign each actor in
  # 2. snapshot the data (every try starts from it)
  # 3. run the actors one at a time in every order (twice in the first order, to spot random columns),
  #    and each actor alone
  # 4. run them together `tries` times with different pauses, and judge each try
  # 5. put the database back exactly as it was before the race
  class Race
    # What the `race "…" do |r| … end` block describes.
    class Definition
      attr_reader :setup_block, :actors, :checks, :tries_override

      def initialize
        @actors = []
        @checks = []
      end

      def setup(&block)
        @setup_block = block
      end

      # An actor that sends requests in its own session:
      #   r.as(:alice) { post … }                       a label, nobody signed in
      #   r.as(users(:alice)) { post … }                signed in as that user
      #   r.as(:alice, sign_in: users(:alice)) { … }    both
      def as(who = nil, sign_in: nil, &block)
        raise ArgumentError, "r.as needs a block with the request(s) to send" unless block

        user = sign_in || (who if who.is_a?(ActiveRecord::Base))
        label = case who
                when Symbol, String then who.to_s
                when ActiveRecord::Base then Sessions.label_for(who)
                else "request #{@actors.size + 1}"
                end
        @actors << { label: unique(label), user: user, block: block, http: true }
      end

      # The same request sent twice at once: a double click, a retry, a webhook delivered twice.
      def twice(who = nil, sign_in: nil, &block)
        2.times { as(who, sign_in: sign_in, &block) }
        @identical = true
      end

      # An actor that isn't a request: a job, a service object, a model method.
      #   r.run(:job) { ChargeOrderJob.perform_now(order.id) }
      def run(label = nil, &block)
        raise ArgumentError, "r.run needs a block" unless block

        @actors << { label: unique((label || "job #{@actors.size + 1}").to_s), block: block, http: false }
      end

      # Optional rules that must hold after every run: r.check("never oversell") { Order.count <= 1 }
      def check(description, &block)
        @checks << [description, block]
      end

      def tries(count)
        @tries_override = Integer(count)
      end

      def identical?
        @identical || false
      end

      private

      def unique(label)
        taken = @actors.map { |actor| actor[:label] }
        return label unless taken.include?(label)

        (2..).lazy.map { |n| "#{label} #{n}" }.find { |candidate| !taken.include?(candidate) }
      end
    end

    def initialize(context, name, tries: nil, location: nil, reproduce: nil, &definition)
      @context = context
      @name = name
      @tries = tries
      @location = location
      @reproduce = reproduce
      @definition = definition
      @config = Deadheat.config
    end

    def run
      started = Deadheat.now
      definition = Definition.new
      @context.instance_exec(definition, &@definition)
      raise ArgumentError, "A race needs at least two actors (r.as, r.twice or r.run)" if definition.actors.size < 2

      connection = Preflight.check!(actors: definition.actors.size)
      Probe.install!
      Source.reset!
      @schema = Schema.new(connection)
      @seed = @config.seed_for_run
      tries = definition.tries_override || @tries || @config.tries

      Writes.clear
      result = nil
      Writes.track do
        original = Snapshot.take(@schema)
        begin
          with_test_job_adapter do
            @context.instance_exec(&definition.setup_block) if definition.setup_block
            @sessions = Sessions.new(@context, definition.actors)
            @base = Snapshot.take(@schema)
            result = race(definition, tries, started)
          end
        ensure
          original.restore(Writes.tables)
        end
      end
      result
    end

    private

    def race(definition, tries, started)
      @checks = definition.checks
      @ignore = Set.new
      warnings = []
      names = @sessions.names
      count = names.size
      # Every order counts as a correct result, even for two copies of the same request: either copy
      # may be the one that gets there first.
      orders = (0...count).to_a.permutation.first(6)

      first = perform(orders.first)
      again = perform(orders.first)
      @ignore = noise(first, again)
      warnings << noise_warning if @ignore.any?
      serial = [first, again].map { |outcome| rebuild(outcome) }
      serial.concat(orders.drop(1).map { |order| perform(order) })
      singles = (definition.identical? ? [0] : (0...count)).map { |i| perform([i], only: i) }

      broken_alone = serial.flat_map(&:failed_checks).uniq
      if broken_alone.any?
        raise Error, "The check “#{broken_alone.first}” fails even when the actors run one at a time, so it can't tell races apart. Fix the check or the setup."
      end

      plan = PausePlan.new(timelines: timelines(first), seed: @seed, max_pause: @config.max_pause)
      counts = Hash.new(0)
      findings = {}
      tries.times do |number|
        schedules, description = plan.for_try(number)
        begin
          outcome = perform(:together, schedules: schedules)
        rescue Hung => e
          counts[:hung] += 1
          findings[[:hung, :hung]] ||= hung_finding(e, number + 1, description)
          break
        end
        verdict = Verdict.judge(outcome, serial: serial, singles: singles, schema: @schema)
        counts[verdict.status] += 1
        next if verdict.ok?

        key = [verdict.status, verdict.kind]
        if findings[key]
          findings[key].count += 1
        else
          findings[key] = Finding.new(verdict: verdict, outcome: outcome, actors: outcome.runners, try: number + 1, pauses: description)
        end
      end

      warnings.concat(Deadheat.internal_errors.map { |e| "Dead Heat hit an internal error and ignored it: #{e.class}: #{e.message}" }.uniq)
      Deadheat.internal_errors.clear
      Result.new(
        name: @name, location: @location, database: database_label, tries: tries, counts: counts,
        findings: findings.values.sort_by { |f| Verdict::STATUSES.index(f.status) || 9 }.reverse,
        seed: @seed, expected: { replies: serial.first.replies.map(&:to_s), changes: serial.first.canon.to_h },
        warnings: warnings, seconds: (Deadheat.now - started).round(2), actors: names,
        reproduce: @reproduce || reproduce_command
      )
    end

    # One run: start from the snapshot, run the actors (in an order, alone, or together), and record
    # what happened.
    def perform(order, schedules: nil, only: nil)
      @base.restore(Writes.tables)
      actors = @sessions.actors
      actors.each_with_index { |actor, i| actor.schedule = schedules&.[](i) }
      effects = Effects.watch do
        if order == :together
          Racer.together(actors, timeout: @config.try_timeout, lock_timeout: @config.lock_timeout)
        else
          Racer.one_by_one(order.map { |i| actors[i] }, timeout: @config.try_timeout, lock_timeout: @config.lock_timeout)
        end
      end
      ran = only ? [actors[only]] : actors
      after = Snapshot.take(@schema, Writes.tables)
      canon = Canon.build(@schema, @base, after, ignore: @ignore)
      replies = actors.map { |actor| ran.include?(actor) ? Outcome.reply_for(actor, canon.new_ids) : nil }
      checks = @checks.map do |description, block|
        [description, ActiveRecord::Base.uncached { @context.instance_exec(&block) } ? true : false]
      end
      Outcome.new(canon: canon, replies: replies, effects: effects, checks: checks, actors: actors.map(&:name), label: order, after: after).tap do |outcome|
        outcome.runners = actors
      end
    end

    def rebuild(outcome)
      canon = Canon.build(@schema, @base, outcome.after, ignore: @ignore)
      Outcome.new(canon: canon, replies: outcome.replies, effects: outcome.effects, checks: outcome.checks,
                  actors: outcome.actors, label: outcome.label, after: outcome.after).tap { |o| o.runners = outcome.runners }
    end

    # Columns that differ between two identical one-at-a-time runs are random (tokens, UUIDs, times
    # stored as text), not racy. Plain columns are checked first, then columns pointing at other rows,
    # whose labels may only have differed because of a random column in the row they point at.
    def noise(first, again)
      ignore = Set.new
      3.times do |round|
        a = Canon.build(@schema, @base, first.after, ignore: ignore)
        b = Canon.build(@schema, @base, again.after, ignore: ignore)
        found = differing_columns(a, b)
        found.reject! { |name| reference_column?(name) } if round.zero?
        break if found.empty? || found.subset?(ignore)

        ignore |= found
      end
      ignore
    end

    def differing_columns(a, b)
      found = Set.new
      (a.tables.keys | b.tables.keys).each do |table|
        x = a.tables[table]
        y = b.tables[table]
        if x.nil? || y.nil? || x.added.size != y.added.size || x.removed != y.removed
          found << "#{table}.*"
          next
        end
        columns = (x.added + y.added).flat_map { |row| row.map(&:first) }.uniq
        columns.each do |column|
          values = ->(rows) { rows.map { |row| row.to_h[column] }.sort_by(&:to_s) }
          found << "#{table}.#{column}" if values.call(x.added) != values.call(y.added)
        end
        xs = x.changed.to_h
        ys = y.changed.to_h
        (xs.keys | ys.keys).each do |key|
          ca = (xs[key] || []).to_h { |column, old, new| [column, [old, new]] }
          cb = (ys[key] || []).to_h { |column, old, new| [column, [old, new]] }
          (ca.keys | cb.keys).each { |column| found << "#{table}.#{column}" if ca[column] != cb[column] }
        end
      end
      found
    end

    def reference_column?(name)
      table, column = name.split(".", 2)
      @schema.references.dig(table, column)
    end

    def noise_warning
      shown = @ignore.to_a.sort.first(6).join(", ")
      "Ignored because they differ even between two identical one-at-a-time runs: #{shown}#{' …' if @ignore.size > 6}"
    end

    def timelines(outcome)
      outcome.runners.map { |actor| PausePlan.steps_from(actor) }
    end

    def hung_finding(error, number, description)
      HungFinding.new(error.message, number, description)
    end

    # A try that never finished. It has no data to compare, only what was running.
    class HungFinding
      attr_reader :message, :try, :pauses
      attr_accessor :count

      def initialize(message, try, pauses)
        @message = message
        @try = try
        @pauses = pauses
        @count = 1
      end

      def status = :hung
      def kind = :hung
      def title = "Hung: #{message}"
      def lines = []
      def why = "A racing request waited longer than the time limit, usually for a row lock held by the other request."
      def fixes = [Fixes::LOCK_TIMEOUT, Fixes::DEADLOCK]
      def irreversible = false
      def timeline = []

      def to_h
        { status: :hung, kind: :hung, title: title, why: why, fixes: fixes, try: try, pauses: pauses, count: count, lines: [], timeline: [] }
      end
    end

    def with_test_job_adapter
      return yield unless defined?(ActiveJob::Base)

      previous = ActiveJob::Base.queue_adapter
      if previous.respond_to?(:enqueued_jobs)
        yield
      else
        ActiveJob::Base.queue_adapter = :test
        begin
          yield
        ensure
          ActiveJob::Base.queue_adapter = previous
        end
      end
    end

    def database_label
      connection = @schema.connection
      version = connection.respond_to?(:database_version) ? connection.database_version.to_s : nil
      name = case connection.adapter_name
             when /postg/i then "PostgreSQL"
             when /mysql|trilogy/i then connection.respond_to?(:mariadb?) && connection.mariadb? ? "MariaDB" : "MySQL"
             when /sqlite/i then "SQLite"
             else connection.adapter_name
             end
      major = version&.then { |v| v.to_s.match?(/\A\d{5,}\z/) ? (v.to_i / 10_000).to_s : v.to_s.split(".").first(2).join(".") }
      [name, major].compact.join(" ")
    rescue StandardError
      @schema.connection.adapter_name
    end

    def reproduce_command
      return unless @location

      file = @location.split(":").first.sub("#{Dir.pwd}/", "")
      runner = file.start_with?("spec/") ? "bundle exec rspec" : "bin/rails test"
      "DEADHEAT_SEED=#{@seed} #{runner} #{@location.sub("#{Dir.pwd}/", '')}"
    end
  end
end
