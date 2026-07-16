# Lokaler Spiegel der PhishTank-Datenbank (bekannte Phishing-URLs).
# Wird periodisch per PhishtankSync aktualisiert (Voll-Import).
class CreateHelpdeskPhishingUrls < ActiveRecord::Migration[6.1]
  def change
    create_table :helpdesk_phishing_urls do |t|
      t.text     :url,         :null => false                 # Original-URL aus dem PhishTank-Feed
      t.string   :url_hash,    :null => false, :limit => 64   # SHA-256 der normalisierten URL (Lookup-Schluessel)
      t.integer  :phish_id                                    # PhishTank-ID (fuer Referenz/Detail-Link)
      t.string   :target                                      # Angegriffene Marke (z. B. "PayPal")
      t.datetime :imported_at, :null => false                 # Zeitpunkt des Imports (fuer stale?-Pruefung)
    end

    add_index :helpdesk_phishing_urls, :url_hash, :unique => true
    add_index :helpdesk_phishing_urls, :phish_id
  end
end
