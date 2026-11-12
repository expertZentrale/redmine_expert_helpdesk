# Syncs the phishing feeds (PhishTank, Phishing.Database) that are due.
#
# Queued by FetchAll after a cron fetch. It used to run inline in that request:
# a due sync downloads and imports tens of thousands of URLs and kept the
# request - and an application server thread - busy for minutes.
# PhishingFeeds.run_if_stale skips feeds that are not due and holds its own lock
# against parallel downloads, so a job queued twice does no harm.
class HelpdeskPhishingFeedsJob < ActiveJob::Base
  queue_as :default

  def perform
    RedmineExpertHelpdesk::PhishingFeeds.run_if_stale
  rescue StandardError => e
    Rails.logger.error "Helpdesk: Feed-Sync fehlgeschlagen: #{e.message}"
  end
end
