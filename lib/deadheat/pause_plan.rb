module Deadheat
  # Decides, for each try, where one request should wait for a moment.
  #
  # Races live in the gap between reading a value and writing it back ("read the stock, then save
  # the stock"). Requests started together usually still run one after the other, because each takes
  # only milliseconds. So the plan looks at a one-at-a-time run, finds each read that is followed by a
  # write to the same table, and in each try pauses ONE request right after such a read for about as
  # long as the other request needs to reach the same read. Then the other request reads the old value
  # too. Which request waits, and at which read, changes from try to try. Every fourth try uses small
  # random pauses instead, and the first try has none at all.
  class PausePlan
    # What one actor does in one try. Keys look like "read:products#1" (the 1st read of products).
    class Schedule
      attr_reader :after_reads, :before_writes, :description

      def initialize(after_reads: {}, before_writes: {}, jitter: nil, description: nil)
        @after_reads = after_reads
        @before_writes = before_writes
        @jitter = jitter
        @description = description
      end

      def after_read(key)
        return @after_reads[key] if @after_reads.key?(key)
        return unless @jitter

        @jitter.rand < 0.5 ? @jitter.rand(0.0..0.005) : nil
      end

      def before_write(key)
        @before_writes[key]
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
      cycle = count + 2 # everyone waits, each actor alone waits, random pauses
      position = k % cycle
      round = k / cycle
      return jitter(rng, count) if position == cycle - 1
      return everyone_waits(rng, count, round) if position.zero?

      victim = position - 1
      gaps = gaps(@timelines[victim])
      return jitter(rng, count) if gaps.empty?

      gap = gaps[round % gaps.size]
      other = (victim + 1) % count
      wait = wait_for(gap, @timelines[victim], @timelines[other], rng, round)
      schedules = Array.new(count)
      schedules[victim] = Schedule.new(after_reads: { gap.key => wait })
      [schedules, "actor #{victim + 1} waits #{(wait * 1000).round} ms after #{describe(gap)}"]
    end

    private

    # Every actor waits right after the same kind of read, so all of them read before any of them
    # writes, whichever one happened to start first.
    def everyone_waits(rng, count, round)
      gaps = gaps(@timelines.first)
      return jitter(rng, count) if gaps.empty?

      gap = gaps[round % gaps.size]
      spread = @timelines.filter_map { |steps| steps.find { |step| step.key == gap.key }&.offset }
      wait = ((spread.max.to_f - spread.min.to_f) + rng.rand(0.004..0.010) * (1 + (round % 3))).clamp(0.002, @max_pause)
      schedules = Array.new(count) { Schedule.new(after_reads: { gap.key => wait }) }
      [schedules, "every request waits #{(wait * 1000).round} ms after #{describe(gap)}"]
    end

    def jitter(rng, count)
      schedules = Array.new(count) { |i| Schedule.new(jitter: Random.new(rng.seed + i)) }
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

    def wait_for(gap, mine, theirs, rng, round)
      same = theirs.find { |step| step.key == gap.key }
      target = same&.offset || theirs.find { |step| step.kind == :write }&.offset || (theirs.last&.offset.to_f / 2)
      base = target - gap.offset
      extra = rng.rand(0.002..0.008) * (1 + (round % 3))
      (base + extra).clamp(0.002, @max_pause)
    end

    def describe(step)
      number = step.key[/#(\d+)\z/, 1].to_i
      "its #{number.ordinalize} read of #{step.tables.join(', ')}"
    end
  end
end
