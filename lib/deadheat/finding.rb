module Deadheat
  # One kind of problem a race found, with the first try that showed it.
  class Finding
    attr_reader :status, :kind, :title, :lines, :why, :fixes, :irreversible, :try, :pauses,
                :timeline, :replies, :expected_replies, :actors
    attr_accessor :count

    def initialize(verdict:, outcome:, actors:, try:, pauses:)
      @status = verdict.status
      @kind = verdict.kind
      @title = verdict.title
      @lines = verdict.lines
      @irreversible = verdict.irreversible
      @try = try
      @pauses = pauses
      @actors = actors.map(&:name)
      @timeline = Explain.timeline(actors)
      @why = Explain.why(actors, verdict.kind)
      error = outcome.replies.find(&:failed?)&.error
      @fixes = Fixes.for(verdict.kind, error: error)
      @replies = outcome.replies.map(&:to_s)
      @expected_replies = verdict.expected&.replies&.map(&:to_s)
      @count = 1
    end

    def to_h
      {
        status: status, kind: kind, title: title, lines: lines, why: why, fixes: fixes,
        irreversible: irreversible, try: try, pauses: pauses, count: count, actors: actors,
        replies: replies, expected_replies: expected_replies, timeline: timeline
      }
    end
  end
end
