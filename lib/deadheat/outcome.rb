# frozen_string_literal: true

module Deadheat
  # Everything one run produced: what changed in the database, what each actor got back, which ones
  # raised, side effects, and the result of each `check`.
  class Outcome
    CONFLICT_ERRORS = %w[ActiveRecord::StaleObjectError].freeze
    CONFLICT_STATUSES = [409, 423].freeze

    Reply = Struct.new(:status, :location, :error) do
      def to_s
        parts = []
        parts << status.to_s if status
        parts << "→ #{location}" if location
        parts << error if error
        parts.empty? ? "finished" : parts.join(" ")
      end

      def failed?
        !error.nil? || status.to_i >= 500
      end

      def conflict?
        CONFLICT_ERRORS.include?(error) || CONFLICT_STATUSES.include?(status)
      end
    end

    attr_reader :canon, :replies, :effects, :checks, :actors, :label, :after
    attr_accessor :runners

    def initialize(canon:, replies:, effects:, checks:, actors:, label:, after:)
      @canon = canon
      @replies = replies
      @effects = effects.masked(canon.new_ids)
      @checks = checks
      @actors = actors
      @label = label
      @after = after
    end

    class << self
      def reply_for(actor, new_ids)
        response = actor.response
        status = location = nil
        if response.respond_to?(:status) && response.respond_to?(:headers)
          status = response.status
          location = response.headers["Location"]&.then { |url| Effects.mask(url.sub(%r{\Ahttps?://[^/]+}, ""), new_ids) }
        end
        exception = actor.error && !actor.error.is_a?(Deadheat::Stop) ? actor.error : nil
        exception ||= response.request.env["action_dispatch.exception"] if response.respond_to?(:request) && response.request
        Reply.new(status, location, error_name(exception))
      end

      # The class, plus the database's own words for a StatementInvalid, which covers many causes
      # ("database is locked", a lock wait timeout).
      def error_name(exception)
        return unless exception

        name = exception.class.name
        return name unless name == "ActiveRecord::StatementInvalid"

        cause = exception.cause&.message || exception.message
        words = cause.to_s.lines.first.to_s.strip.sub(/\A[\w:]+:\s*/, "")[0, 60]
        words.empty? ? name : "#{name} (#{words})"
      end
    end

    # Same data, same side effects, same replies, same checks.
    def same_as?(other)
      same_data_as?(other) && replies == other.replies && checks == other.checks
    end

    def same_data_as?(other)
      canon == other.canon && effects == other.effects
    end

    def failed_checks
      checks.reject { |_, ok| ok }.map(&:first)
    end
  end
end
