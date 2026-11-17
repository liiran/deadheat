module Deadheat
  # Things a run did outside the database that can't be taken back: emails delivered, background
  # jobs queued and HTTP calls to other services (seen through WebMock when the app uses it).
  class Effects
    # Jobs whose names suggest money, shipping or messages to people. A duplicate of one of these, or
    # any duplicate email or outside POST/PUT/PATCH/DELETE, is labelled "irreversible".
    IRREVERSIBLE_JOB = /mail|charge|pay|refund|capture|ship|fulfil|deliver|notif|webhook|sms|push|invoice|transfer|payout/i

    attr_reader :mails, :jobs, :http

    def self.watch
      marks = { mails: mail_count, jobs: job_count, http: http_counts }
      yield
      new(
        mails: new_mails(marks[:mails]),
        jobs: new_jobs(marks[:jobs]),
        http: new_http(marks[:http])
      )
    end

    def initialize(mails: [], jobs: [], http: [])
      @mails = mails
      @jobs = jobs
      @http = http
    end

    def masked(ids)
      Effects.new(
        mails: @mails.map { |mail| mail.map { |part| Effects.mask(part, ids) } }.sort,
        jobs: @jobs.map { |job| job.map { |part| Effects.mask(part, ids) } }.sort,
        http: @http.map { |call| Effects.mask(call, ids) }.sort
      )
    end

    def to_a
      [mails, jobs, http]
    end

    def ==(other)
      other.is_a?(Effects) && to_a == other.to_a
    end
    alias eql? ==

    def hash
      to_a.hash
    end

    def empty?
      mails.empty? && jobs.empty? && http.empty?
    end

    # What this run did more often than the expected run, as sentences, and whether any of it can't
    # be taken back.
    def extra_over(expected)
      lines = []
      irreversible = false
      extra(mails, expected.mails).each do |(to, subject), n|
        lines << "#{n} extra email#{'s' if n > 1} to #{to}: “#{subject}”"
        irreversible = true
      end
      extra(jobs, expected.jobs).each do |(job, _args), n|
        lines << "#{job} queued #{n} more time#{'s' if n > 1}"
        irreversible ||= job.match?(IRREVERSIBLE_JOB)
      end
      extra(http, expected.http).each do |call, n|
        lines << "#{call} called #{n} more time#{'s' if n > 1}"
        irreversible ||= !call.start_with?("GET ", "HEAD ")
      end
      [lines, irreversible]
    end

    class << self
      def mask(text, ids)
        return text if ids.empty?

        text.to_s.gsub(/\d+/) { |digits| ids.include?(digits) ? ":new" : digits }
      end

      private

      def mail_count
        defined?(ActionMailer::Base) ? ActionMailer::Base.deliveries.size : 0
      end

      def new_mails(mark)
        return [] unless defined?(ActionMailer::Base)

        ActionMailer::Base.deliveries.drop(mark).map { |mail| [Array(mail.to).sort.join(", "), mail.subject.to_s] }
      end

      def job_adapter
        return unless defined?(ActiveJob::Base)

        adapter = ActiveJob::Base.queue_adapter
        adapter if adapter.respond_to?(:enqueued_jobs)
      end

      def job_count
        job_adapter&.enqueued_jobs&.size.to_i
      end

      def new_jobs(mark)
        adapter = job_adapter
        return [] unless adapter

        adapter.enqueued_jobs.drop(mark).map do |job|
          name = job[:job].to_s
          name = "#{job[:args].first.to_s}##{job[:args][1]}" if name == "ActionMailer::MailDeliveryJob" && job[:args].is_a?(Array)
          [name, job[:args].to_json.to_s[0, 200]]
        end
      end

      def http_counts
        return {} unless defined?(WebMock::RequestRegistry)

        WebMock::RequestRegistry.instance.requested_signatures.hash.dup
      end

      def new_http(mark)
        return [] unless defined?(WebMock::RequestRegistry)

        now = WebMock::RequestRegistry.instance.requested_signatures.hash
        now.flat_map do |signature, n|
          extra = n - mark.fetch(signature, 0)
          extra.positive? ? ["#{signature.method.to_s.upcase} #{signature.uri.omit(:query)}"] * extra : []
        end
      end
    end

    private

    def extra(mine, theirs)
      counts = Hash.new(0)
      mine.each { |item| counts[item] += 1 }
      theirs.each { |item| counts[item] -= 1 }
      counts.select { |_, n| n.positive? }
    end
  end
end
