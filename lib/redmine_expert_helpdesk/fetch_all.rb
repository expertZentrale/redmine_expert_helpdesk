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
#   FAILURES_BEFORE_DEFERRING times in a row is not asked again in the same run:
#   its other mailboxes are deferred. One failure is not enough - an Exchange
#   outage often hits only the mailboxes on some of its servers, and one broken
#   mailbox must not hold back all the others.
#
# Mailboxes take turns: a run starts with the one attempted longest ago
# (last_fetched_at / last_error_at, never attempted first). A mailbox that keeps
# failing moves to the back; the ones a run deferred or the budget cut off come
# first next time. In a fixed order the same mailboxes would always be last and
# never fetched while a service struggles.
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

    # Service failures in a row (a success resets the count) after which the
    # remaining mailboxes of that service are deferred to the next run.
    FAILURES_BEFORE_DEFERRING = 3

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

      # Longest since the last attempt first, never attempted before all; the id
      # keeps the order stable among equals.
      def in_turn(mailboxes)
        mailboxes.sort_by do |mailbox|
          last = [mailbox.last_fetched_at, mailbox.last_error_at].compact.max
          [last ? 1 : 0, last.to_f, mailbox.id.to_i]
        end
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
      failures = Hash.new(0)
      summary = {}

      self.class.in_turn(@mailboxes).each do |mailbox|
        next unless mailbox.project&.active? && mailbox.project.module_enabled?(:helpdesk)

        address = mailbox.mailbox_address
        service = self.class.service_key(mailbox)
        if failures[service] >= FAILURES_BEFORE_DEFERRING
          summary[address] = { :deferred => 'service_unavailable' }
          next
        end
        if self.class.clock >= deadline
          summary[address] = { :deferred => 'time_budget' }
          next
        end

        summary[address], unavailable = fetch(mailbox, deadline)
        failures[service] = unavailable ? failures[service] + 1 : 0
      end

      log_deferred(summary)
      run_phishing_feeds if self.class.clock < deadline
      summary
    end

    private

    # [result hash, whether the service turned out to be unavailable]
    def fetch(mailbox, deadline)
      processor = MailProcessor.new(mailbox)
      result = processor.process_all(LIMIT, :deadline => deadline).to_h
      [result, processor.service_unavailable?]
    rescue StandardError => e
      Rails.logger.error "Helpdesk: Abruf fuer #{mailbox.mailbox_address} fehlgeschlagen: #{e.message}"
      record_error(mailbox, e)
      [{ :error => e.message }, MailProvider.service_unavailable?(e)]
    end

    # process_all records its outcome on the mailbox itself. An error raised out
    # of it (IMAP's session timeout) would leave the mailbox looking untried, and
    # so first in line on every run.
    def record_error(mailbox, error)
      mailbox.update_columns(:last_error    => I18n.t(:error_helpdesk_fetch_failed, :message => error.message),
                             :last_error_at => Time.current)
    rescue StandardError => e
      Rails.logger.warn "Helpdesk: Fehler fuer #{mailbox.mailbox_address} nicht gespeichert: #{e.message}"
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
