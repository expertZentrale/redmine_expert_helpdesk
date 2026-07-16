# Lokaler Spiegel der PhishTank-Datenbank.
# Eine Zeile pro bekannter Phishing-URL; Lookup erfolgt ueber den SHA-256-Hash
# der normalisierten URL (Index), nicht ueber die URL selbst (TEXT-Spalte).
require 'digest'

class HelpdeskPhishingUrl < HelpdeskApplicationRecord
  # Feed-Quellen des Spiegels
  SOURCES = %w[phishtank phishing_database].freeze

  BATCH_SIZE = 1000

  validates :url,      :presence => true
  validates :url_hash, :presence => true, :uniqueness => true

  # Normalisiert eine URL fuer den Vergleich:
  # Schema und Host kleinschreiben, Fragment entfernen, Trailing-Slash des Pfads entfernen.
  def self.normalize(url)
    u = url.to_s.strip
    return '' if u.empty?

    begin
      parsed = URI.parse(u)
      parsed.scheme = parsed.scheme&.downcase
      parsed.host = parsed.host&.downcase
      parsed.fragment = nil
      normalized = parsed.to_s
    rescue URI::Error
      normalized = u
    end

    normalized.sub(%r{/+\z}, '')
  end

  def self.hash_for(url)
    Digest::SHA256.hexdigest(normalize(url))
  end

  # Sucht eine URL im Spiegel. Liefert den Datensatz oder nil.
  def self.lookup(url)
    normalized = normalize(url)
    return nil if normalized.empty?

    find_by(:url_hash => Digest::SHA256.hexdigest(normalized))
  end

  # Ist die Quelle (bzw. der gesamte Spiegel) aelter als das Intervall oder leer?
  def self.stale?(interval_hours, source = nil)
    scope = source.present? ? where(:source => source) : all
    last_import = scope.maximum(:imported_at)
    return true if last_import.nil?

    last_import < interval_hours.to_i.hours.ago
  end

  # Ersetzt alle Eintraege einer Quelle in einer Transaktion.
  # Duplikate zu anderen Quellen (gleicher url_hash) werden von insert_all
  # uebersprungen (Unique-Index). Liefert die Anzahl der Rows.
  def self.replace_source!(source, rows)
    with_utf8mb4_connection do
      transaction do
        where(:source => source).delete_all
        rows.each_slice(BATCH_SIZE) do |batch|
          insert_all(batch)
        end
      end
    end
    rows.size
  end

  # Stellt die Session waehrend des Imports auf utf8mb4 um.
  # Hintergrund: Redmines database.yml nutzt encoding utf8 (= utf8mb3); der
  # Server lehnt 4-Byte-UTF-8 (Homoglyphen-Domains in den Feeds) dann bereits
  # auf Verbindungsebene ab, obwohl die Tabelle utf8mb4 ist.
  def self.with_utf8mb4_connection
    conn = connection
    return yield unless conn.adapter_name =~ /mysql/i

    previous = conn.select_value('SELECT @@character_set_client').to_s
    return yield if previous == 'utf8mb4'

    conn.execute('SET NAMES utf8mb4')
    begin
      yield
    ensure
      conn.execute("SET NAMES #{previous}") if previous.present?
    end
  end
end
