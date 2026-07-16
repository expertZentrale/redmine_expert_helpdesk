# Orchestriert die Phishing-Feed-Synchronisation (PhishTank + Phishing.Database):
# - run_if_stale: automatischer Sync beim Mailabruf (fetch_all), pro Quelle
#   nur wenn das Intervall abgelaufen ist; Rails.cache-Lock gegen Doppellaeufe
# - run_all: manueller Sync (Button in den Plugin-Einstellungen, Rake-Task)
module RedmineExpertHelpdesk
  class PhishingFeeds
    LOCK_KEY = 'redmine_expert_helpdesk/phishing_feeds_sync_lock'.freeze

    # Liefert die aktivierten Feeds als [[source, sync_objekt], ...].
    # PhishTank ist immer dabei (Master-Schalter phishtank_enabled ist
    # Voraussetzung fuer die gesamte Phishing-Funktion).
    def self.enabled_feeds(settings)
      feeds = [
        [PhishtankSync::SOURCE, PhishtankSync.new(settings['phishtank_app_key'], settings['phishtank_feed_url'])]
      ]
      if settings['phishing_database_enabled'] == '1'
        feeds << [PhishingDatabaseSync::SOURCE, PhishingDatabaseSync.new(settings['phishing_database_feed_url'])]
      end
      feeds
    end

    # Manueller Sync aller aktivierten Feeds.
    # Liefert [results, errors]: { source => anzahl } / { source => fehlermeldung }.
    def self.run_all
      settings = Setting.plugin_redmine_expert_helpdesk
      results = {}
      errors  = {}
      return [results, errors] unless settings['phishtank_enabled'] == '1'

      enabled_feeds(settings).each do |source, sync|
        begin
          results[source] = sync.run
        rescue StandardError => e
          errors[source] = e.message
        end
      end

      [results, errors]
    end

    # Automatischer Sync: nur faellige Quellen, mit Lock gegen parallele Downloads.
    # Liefert true wenn mindestens ein Sync gelaufen ist.
    def self.run_if_stale
      settings = Setting.plugin_redmine_expert_helpdesk
      return false unless settings['phishtank_enabled'] == '1'

      interval = [settings['phishtank_interval_hours'].to_i, 1].max
      due = enabled_feeds(settings).select do |source, _sync|
        HelpdeskPhishingUrl.stale?(interval, source)
      end
      return false if due.empty?

      return false unless Rails.cache.write(LOCK_KEY, Time.current.to_i, :unless_exist => true, :expires_in => 30.minutes)

      begin
        due.each do |source, sync|
          begin
            sync.run
          rescue StandardError => e
            Rails.logger.error "Helpdesk: Feed-Sync '#{source}' fehlgeschlagen: #{e.message}"
          end
        end
        true
      ensure
        Rails.cache.delete(LOCK_KEY)
      end
    end
  end
end
