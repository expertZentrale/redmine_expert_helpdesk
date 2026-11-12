# The fetch of every enabled mailbox behind GET /helpdesk/fetch_all, which a
# cron job calls every few minutes.
#
# It runs inside a web request, so it holds one of the application server's few
# threads for as long as it takes. When the mail service hangs, that adds up: in
# the Exchange Online outage of 2026-11-12 every Graph call took 30 s and then
# failed, one run over seven mailboxes took over three minutes, a proxy in front
# retried the request every two minutes while Redmine finished each attempt, and
# within ten minutes no thread was left for anyone else - Redmine was down for
# everybody, login included. Three guards keep a run short and single:
#
# * One run at a time across all processes (cache lock, Redis in production; the
#   same pattern as SlaBreachCheck). A second call returns at once.
# * A time budget: after it, no further mailbox and no further message is
#   started. What is left stays unread for the next run.
# * A service that timed out or answered 5xx/429 (MailProvider.service_unavailable?)
#   is not asked again in the same run: its other mailboxes are deferred, so an
#   outage costs one timeout per run instead of one per mailbox.
module RedmineExpertHelpdesk
  class FetchAll
    LOCK_KEY = 'redmine_expert_helpdesk/fetch_all_lock'.freeze

    # Seconds. Well below a five-minute cron interval, so a run is over before
    # the next one is due, and below the cron's own client timeout.
    TIME_BUDGET = 150

    # Outlives every run that keeps its budget (a message may still be in
    # progress when the budget runs out). Only matters when a process dies
    # holding the lock: fetching resumes after this at the latest.
    LOCK_TTL = 10.minutes

    # Seconds before LOCK_TTL from which a run no longer deletes the lock on
    # its own (see run).
    RELEASE_MARGIN = 60

    # Messages per mailbox and run, as for the project's "fetch now" button.
    LIMIT = 25

    class << self
      # Fetches +mailboxes+ and returns { address => result hash }, or nil when
      # another run holds the lock.
      def run(mailboxes)
        return nil unless Rails.cache.write(LOCK_KEY, Time.current.to_i, :unless_exist => true, :expires_in => LOCK_TTL)

        started = clock
        begin
          new(mailboxes).run
        ensure
          # Cache stores offer no atomic compare-and-delete, and reading the
          # entry before deleting it leaves a gap. Well inside LOCK_TTL the entry
          # cannot have expired, so it is still ours; a run that came close to
          # LOCK_TTL leaves it to expire rather than delete the next run's lock.
          Rails.cache.delete(LOCK_KEY) if clock - started < LOCK_TTL.to_i - RELEASE_MARGIN
        end
      end

      # Monotonic seconds, immune to clock changes and to the frozen time of
      # Redmine's tests. One place to stub.
      def clock
        Process.clock_gettime(Process::CLOCK_MONOTONIC)
      end

      # Mailboxes that share this key share a service: every Graph mailbox talks
      # to the same tenant, IMAP mailboxes to their server.
      def service_key(mailbox)
        mailbox.imap? ? "imap:#{mailbox.imap_host.to_s.downcase}" : 'graph'
      end
    end

    def initialize(mailboxes, budget = TIME_BUDGET)
      @mailboxes = mailboxes
      @budget = budget
    end

    # Deferred mailboxes report { :deferred => 'service_unavailable' | 'time_budget' }
    # instead of a result; their messages wait unread for the next run.
    def run
      deadline = self.class.clock + @budget
      unavailable = {}
      summary = {}

      @mailboxes.each do |mailbox|
        next unless mailbox.project&.active? && mailbox.project.module_enabled?(:helpdesk)

        address = mailbox.mailbox_address
        service = self.class.service_key(mailbox)
        if unavailable[service]
          summary[address] = { :deferred => 'service_unavailable' }
          next
        end
        if self.class.clock >= deadline
          summary[address] = { :deferred => 'time_budget' }
          next
        end

        summary[address] = fetch(mailbox, deadline) { unavailable[service] = true }
      end

      log_deferred(summary)
      run_phishing_feeds if self.class.clock < deadline
      summary
    end

    private

    # Yields when the service turned out to be unavailable.
    def fetch(mailbox, deadline)
      processor = MailProcessor.new(mailbox)
      result = processor.process_all(LIMIT, :deadline => deadline).to_h
      yield if processor.service_unavailable?
      result
    rescue StandardError => e
      Rails.logger.error "Helpdesk: Abruf fuer #{mailbox.mailbox_address} fehlgeschlagen: #{e.message}"
      yield if MailProvider.service_unavailable?(e)
      { :error => e.message }
    end

    def log_deferred(summary)
      deferred = summary.select { |_address, result| result.key?(:deferred) }
      return if deferred.empty?

      reasons = deferred.values.map { |result| result[:deferred] }.uniq.join(', ')
      Rails.logger.warn "Helpdesk: fetch_all deferred #{deferred.size} mailbox(es) to the next run (#{reasons}): " \
                        "#{deferred.keys.join(', ')}"
    end

    # Phishing feeds piggyback on the cron run, as a job: a due sync downloads
    # and imports tens of thousands of URLs and took minutes inline, holding the
    # web thread all along. Their failures must never touch the mail fetch.
    def run_phishing_feeds
      HelpdeskPhishingFeedsJob.perform_later if PhishingFeeds.due?
    rescue StandardError => e
      Rails.logger.error "Helpdesk: Feed-Sync im fetch_all fehlgeschlagen: #{e.message}"
    end
  end
end
