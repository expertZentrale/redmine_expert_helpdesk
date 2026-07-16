# Laedt den Phishing.Database-Feed (github.com/Phishing-Database/Phishing.Database)
# herunter und spiegelt ihn in die Tabelle helpdesk_phishing_urls
# (Quelle: 'phishing_database').
#
# Der Feed ist eine Plain-Text-Liste (eine URL pro Zeile, aktive Phishing-Links,
# per PyFunceble validiert). Kein API-Key erforderlich.
#
# Orchestrierung (Intervall, Lock, mehrere Feeds): PhishingFeeds.

require 'net/http'
require 'uri'
require 'zlib'
require 'stringio'

module RedmineExpertHelpdesk
  class PhishingDatabaseSync
    DEFAULT_FEED_URL = 'https://raw.githubusercontent.com/Phishing-Database/Phishing.Database/master/phishing-links-ACTIVE.txt'.freeze
    USER_AGENT = 'redmine-expert-helpdesk'.freeze
    SOURCE     = 'phishing_database'.freeze

    class SyncError < StandardError; end

    def initialize(feed_url = nil)
      @feed_url = feed_url.to_s.strip
    end

    # Download + Voll-Import der Quelle 'phishing_database' in einer Transaktion.
    # Bei Fehlern bleiben die alten Daten unveraendert erhalten.
    def run
      body = fetch_body
      rows = build_rows(body, Time.current)
      raise SyncError, 'Phishing.Database-Feed ist leer' if rows.empty?

      count = HelpdeskPhishingUrl.replace_source!(SOURCE, rows)

      Rails.logger.info "Helpdesk: Phishing.Database-Sync abgeschlossen – #{count} URLs importiert"
      count
    rescue SyncError, StandardError => e
      Rails.logger.error "Helpdesk: Phishing.Database-Sync fehlgeschlagen: #{e.message}"
      raise SyncError, e.message
    end

    private

    def feed_url
      @feed_url.presence || DEFAULT_FEED_URL
    end

    def fetch_body(redirect_limit = 3)
      raise SyncError, 'Zu viele Redirects beim Phishing.Database-Download' if redirect_limit.zero?

      uri = URI.parse(@redirect_url || feed_url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl      = (uri.scheme == 'https')
      http.open_timeout = 15
      http.read_timeout = 180

      request = Net::HTTP::Get.new(uri)
      request['User-Agent'] = USER_AGENT

      response = http.request(request)

      case response
      when Net::HTTPSuccess
        decompress(response)
      when Net::HTTPRedirection
        @redirect_url = response['location']
        fetch_body(redirect_limit - 1)
      when Net::HTTPTooManyRequests
        raise SyncError, 'Phishing.Database-Rate-Limit erreicht (HTTP 429) – Intervall erhoehen'
      else
        raise SyncError, "Phishing.Database-Download fehlgeschlagen (HTTP #{response.code})"
      end
    end

    # Antwort ggf. entpacken (GitHub liefert je nach Header gzip-komprimiert).
    def decompress(response)
      body = response.body.to_s
      if response['content-encoding'].to_s.include?('gzip') || body.start_with?("\x1f\x8b".b)
        Zlib::GzipReader.new(StringIO.new(body)).read
      else
        body
      end
    end

    # Eine URL pro Zeile; Leerzeilen und Kommentare ueberspringen,
    # Zeilen ohne Schema als http:// interpretieren (Domain-Listen).
    def build_rows(body, now)
      seen = {}
      body.force_encoding('UTF-8').scrub(' ').split(/\r?\n/).each_with_object([]) do |line, rows|
        url = line.strip
        next if url.empty? || url.start_with?('#')

        url = "http://#{url}" unless url =~ %r{\Ahttps?://}i

        hash = HelpdeskPhishingUrl.hash_for(url)
        next if seen[hash]

        seen[hash] = true
        rows << {
          :url         => url,
          :url_hash    => hash,
          :phish_id    => nil,
          :target      => nil,
          :source      => SOURCE,
          :imported_at => now
        }
      end
    end
  end
end
