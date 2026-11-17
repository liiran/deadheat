module Deadheat
  # Decides, for each try, where requests should wait for a moment.
  #
  # Races live in the gap between reading a value and writing it back ("read the stock, then save
  # the stock"). Requests started together usually still run one after the other, because each takes
  # only milliseconds. So the plan looks at a one-at-a-time run, finds each read that is followed by a
  # write to the same table, and widens that gap in one of three ways, changing from try to try:
  #
  # - meet:    every request waits right after that read until the others have made the same read
  #            (at most max_pause), so all of them read before any of them writes.
  # - first:   whichever request makes that read first waits a fixed while, so another one reads,
  #            and maybe writes, in between.
  # - random:  small random pauses after reads, for orderings the other two don't produce.
  #
  # The first try has no pauses at all.
  class PausePlan
    # What one actor does in one try. Keys look like "read:products#1" (the 1st read of products).
    class Schedule
      attr_reader :description

      def initialize(after_reads: {}, meet: nil, first: nil, jitter: nil, max_pause: 0.25)
        @after_reads = after_reads
        @meet = meet
        @first = first
        @jitter = jitter
        @max_pause = max_pause
      end

      # Waits if this read is a pause point. Returns the seconds waited, or nil.
      def after_read(key)
        if @meet && @meet[:key] == key && !@met
          @met = true
          started = Deadheat.now
          @meet[:latch].count_down
          @meet[:latch].wait(@max_pause)
          return Deadheat.now - started
        end
        if @first && @first[:key] == key && @first[:taken].make_true
          sleep(@first[:seconds])
          return @first[:seconds]
        end
        seconds = @after_reads[key]
        seconds ||= @jitter.rand < 0.5 ? @jitter.rand(0.0..0.005) : nil if @jitter
        return unless seconds

        sleep(seconds)
        seconds
      end

      def before_write(_key)
        nil
      end
    end

    # A timeline entry from the one-at-a-time run: [key, kind, tables, offset in seconds from the
    # actor's start].
    Step = Struct.new(:key, :kind, :tables, :offset)

    attr_reader :seed

    def initialize(timelines:, seed:, max_pause: 0.25)
      @timelines = timelines
      @seed = seed
      @max_pause = max_pause
    end

    def self.steps_from(actor)
      actor.events.filter_map do |event|
        next unless %i[read write].include?(event.kind) && event.key

        Step.new(event.key, event.kind, event.tables, event.started - actor.t0)
      end
    end

    # One schedule per actor (nil means "don't pause this one") and a sentence saying what was tried.
    def for_try(number)
      count = @timelines.size
      return [Array.new(count), "no pauses"] if number.zero? || count < 2

      k = number - 1
      rng = Random.new(seed * 1_000 + number)
      # meet, first-waits, meet at the next gap, first-waits longer at the next gap, random
      round = k / 5
      case k % 5
      when 0 then meet(count, round * 2)
      when 1 then first_waits(count, round * 2, rng, 1)
      when 2 then meet(count, round * 2 + 1)
      when 3 then first_waits(count, round * 2 + 1, rng, 3)
      else jitter(rng, count)
      end
    end

    private

    # Whichever request makes the read first waits a while, long enough for another to read (and
    # perhaps write) in between.
    def first_waits(count, index, rng, scale)
      gaps = gaps(@timelines.first)
      return jitter(rng, count) if gaps.empty?

      gap = gaps[index % gaps.size]
      wait = (others_reach(gap) + rng.rand(0.003..0.008) * scale).clamp(0.002, @max_pause)
      first = { key: gap.key, seconds: wait, taken: Concurrent::AtomicBoolean.new(false) }
      schedules = Array.new(count) { Schedule.new(first: first, max_pause: @max_pause) }
      [schedules, "whichever request makes #{describe(gap)} first waits #{(wait * 1000).round} ms"]
    end

    # How much later than the first actor the others reach the same read, in the one-at-a-time run.
    def others_reach(gap)
      offsets = @timelines.filter_map { |steps| steps.find { |step| step.key == gap.key }&.offset }
      offsets.size > 1 ? offsets.max - offsets.min : 0.0
    end

    def meet(count, index)
      gaps = gaps(@timelines.first)
      return jitter(Random.new(seed + index), count) if gaps.empty?

      gap = gaps[index % gaps.size]
      latch = Concurrent::CountDownLatch.new(count)
      schedules = Array.new(count) { Schedule.new(meet: { key: gap.key, latch: latch }, max_pause: @max_pause) }
      [schedules, "every request waits after #{describe(gap)} until all have made it"]
    end

    def jitter(rng, count)
      schedules = Array.new(count) { |i| Schedule.new(jitter: Random.new(rng.seed + i), max_pause: @max_pause) }
      [schedules, "small random pauses after reads"]
    end

    # Reads followed later by a write to one of the same tables. If there are none, any read before
    # the last write; if nothing is written at all, every read.
    def gaps(steps)
      reads = steps.each_with_index.select { |step, _| step.kind == :read && step.tables.any? }
      paired = reads.select do |read, i|
        steps[(i + 1)..].any? { |later| later.kind == :write && (later.tables & read.tables).any? }
      end
      return paired.map(&:first) if paired.any?

      last_write = steps.rindex { |step| step.kind == :write }
      return reads.select { |_, i| i < last_write }.map(&:first) if last_write

      reads.map(&:first)
    end


    def describe(step)
      number = step.key[/#(\d+)\z/, 1].to_i
      "its #{number.ordinalize} read of #{step.tables.join(', ')}"
    end

  end
end
