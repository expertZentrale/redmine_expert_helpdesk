# Laedt die PhishTank-Datenbank (online-valid.json.gz) herunter und
# spiegelt sie in die Tabelle helpdesk_phishing_urls (Quelle: 'phishtank').
#
# Ohne App-Key wird der anonyme Endpunkt verwendet (strengeres Rate-Limit,
# Intervall nicht unter 1 Stunde waehlen). PhishTank verlangt einen
# aussagekraeftigen User-Agent im Format "phishtank/<name>".
#
# Orchestrierung (Intervall, Lock, mehrere Feeds): PhishingFeeds.

require 'net/http'
require 'uri'
require 'json'
require 'zlib'
require 'stringio'

module RedmineExpertHelpdesk
  class PhishtankSync
    # Voreingestellte Feed-URL; {key} wird durch den App-Key ersetzt (falls vorhanden).
    # Ohne Key wird das Pfadsegment "/{key}" komplett entfernt (anonymer Endpunkt).
    DEFAULT_FEED_URL = 'https://data.phishtank.com/data/{key}/online-valid.json.gz'.freeze
    USER_AGENT = 'phishtank/redmine-expert-helpdesk'.freeze
    SOURCE     = 'phishtank'.freeze

    class SyncError < StandardError; end

    def initialize(app_key = nil, feed_url_template = nil)
      @app_key = app_key.to_s.strip
      @feed_url_template = feed_url_template.to_s.strip
    end

    # Download + Voll-Import der Quelle 'phishtank' in einer Transaktion.
    # Bei Fehlern bleiben die alten Daten unveraendert erhalten.
    def run
      entries = fetch_entries
      raise SyncError, 'PhishTank-Feed ist leer' if entries.empty?

      rows = build_rows(entries, Time.current)
      count = HelpdeskPhishingUrl.replace_source!(SOURCE, rows)

      Rails.logger.info "Helpdesk: PhishTank-Sync abgeschlossen – #{count} URLs importiert"
      count
    rescue SyncError, StandardError => e
      Rails.logger.error "Helpdesk: PhishTank-Sync fehlgeschlagen: #{e.message}"
      raise SyncError, e.message
    end

    private

    # Baut die effektive Feed-URL aus der konfigurierten Vorlage:
    # - {key} wird durch den App-Key ersetzt
    # - ohne App-Key wird das Pfadsegment "/{key}" entfernt (anonymer Endpunkt)
    def feed_url
      template = @feed_url_template.presence || DEFAULT_FEED_URL
      if @app_key.present?
        template.gsub('{key}', @app_key)
      else
        template.gsub('/{key}', '').gsub('{key}', '')
      end
    end

    def fetch_entries(redirect_limit = 3)
      raise SyncError, 'Zu viele Redirects beim PhishTank-Download' if redirect_limit.zero?

      uri = URI.parse(@redirect_url || feed_url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl      = (uri.scheme == 'https')
      http.open_timeout = 15
      http.read_timeout = 120

      request = Net::HTTP::Get.new(uri)
      request['User-Agent'] = USER_AGENT

      response = http.request(request)

      case response
      when Net::HTTPSuccess
        parse_gzip_json(response.body)
      when Net::HTTPRedirection
        @redirect_url = response['location']
        fetch_entries(redirect_limit - 1)
      when Net::HTTPTooManyRequests
        raise SyncError, 'PhishTank-Rate-Limit erreicht (HTTP 429) – Intervall erhoehen'
      else
        raise SyncError, "PhishTank-Download fehlgeschlagen (HTTP #{response.code})"
      end
    end

    def parse_gzip_json(body)
      json = Zlib::GzipReader.new(StringIO.new(body)).read
      JSON.parse(json)
    rescue Zlib::GzipFile::Error
      # Feed kam unkomprimiert (Content-Negotiation) – direkt parsen
      JSON.parse(body)
    rescue JSON::ParserError => e
      raise SyncError, "PhishTank-Feed nicht lesbar: #{e.message}"
    end

    # Baut insert_all-Rows; Duplikate (gleicher Hash) werden uebersprungen.
    def build_rows(entries, now)
      seen = {}
      entries.each_with_object([]) do |entry, rows|
        url = entry['url'].to_s
        next if url.empty?

        hash = HelpdeskPhishingUrl.hash_for(url)
        next if seen[hash]

        seen[hash] = true
        rows << {
          :url         => url,
          :url_hash    => hash,
          :phish_id    => entry['phish_id'].to_i,
          :target      => entry['target'].to_s.presence,
          :source      => SOURCE,
          :imported_at => now
        }
      end
    end
  end
end
