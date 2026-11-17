module Deadheat
  # One side of a race: a request (or job, or any block) that runs in its own thread with its own
  # database connection. It records every query it sends and, when the pause plan says so, waits a
  # moment right after a read or right before a write.
  class Actor
    Event = Struct.new(:actor, :seq, :kind, :sql, :tables, :locking, :key, :started, :ms, :source,
                       :rows, :done, :paused_after, :paused_before, keyword_init: true) do
      def to_h
        super.merge(tables: tables.to_a)
      end
    end

    attr_reader :name, :index, :events, :block
    attr_accessor :schedule, :t0, :finished, :error, :response, :context

    def initialize(name:, index:, block:, context: nil)
      @name = name
      @index = index
      @block = block
      @context = context
      reset!
    end

    def reset!
      @events = []
      @stack = []
      @counts = Hash.new(0)
      @seq = 0
      @schedule = nil
      @t0 = nil
      @finished = nil
      @error = nil
      @response = nil
    end

    def duration
      return 0 unless t0 && finished

      finished - t0
    end

    # Called by the probe when a query starts in this actor's thread.
    def query_started(payload)
      info = classify(payload)
      @stack << [info, Deadheat.now]
      return unless info && info.kind == :write

      info.key = next_key(info)
      info.paused_before = schedule&.before_write(info.key)
    end

    # Called by the probe when that query finishes.
    def query_finished(payload)
      info, started = @stack.pop
      return unless info

      info.key ||= next_key(info) if info.kind == :read
      info.started = started
      info.done = Deadheat.now
      info.ms = ((info.done - started) * 1000).round(2)
      info.source = Source.locate
      info.rows = payload[:row_count]
      info.seq = (@seq += 1)
      @events << info
      return unless info.kind == :read && !info.locking

      # The schedule does the waiting itself and says how long it waited.
      info.paused_after = schedule&.after_read(info.key)
    end

    private

    def classify(payload)
      return nil if SQL.internal?(payload)

      sql = payload[:sql].to_s
      kind = payload[:name] == "TRANSACTION" ? :transaction : SQL.kind(sql)
      return nil if kind == :other

      Event.new(actor: name, kind: kind, sql: SQL.readable(payload), tables: SQL.tables(sql, kind),
                locking: kind == :read && SQL.locking?(sql))
    end

    # "the 2nd read of products": stable between runs even if other queries come and go.
    def next_key(info)
      base = "#{info.kind}:#{info.tables.sort.join(',')}"
      "#{base}##{@counts[base] += 1}"
    end
  end
end
