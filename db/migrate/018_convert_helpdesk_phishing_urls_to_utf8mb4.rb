# PhishTank-URLs enthalten 4-Byte-UTF-8-Zeichen (Homoglyphen-Domains wie
# mathematische Buchstaben, ein gaengiger Phishing-Trick). Redmines
# Standard-Charset utf8mb3 kann diese nicht speichern (Mysql2::Error:
# Incorrect string value) – Tabelle auf utf8mb4 konvertieren.
class ConvertHelpdeskPhishingUrlsToUtf8mb4 < ActiveRecord::Migration[6.1]
  def up
    return unless ActiveRecord::Base.connection.adapter_name =~ /mysql/i

    execute 'ALTER TABLE helpdesk_phishing_urls CONVERT TO CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci'
  end

  def down
    # Keine Rueckkonvertierung: utf8mb4 ist abwaertskompatibel zu utf8mb3
  end
end
