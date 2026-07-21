# Protokolleintrag einer KI-Zusammenfassung (Provider/Modell + Token-Verbrauch),
# verknuepft mit der erzeugten privaten Journal-Notiz. Bewusst KEIN Activity-Provider
# (im Gegensatz zu HelpdeskMessage) – die Zusammenfassung soll den Aktivitaets-Feed
# nicht zumuellen; der Eintrag dient nur der Token-Anzeige im Journal-Header.
class HelpdeskAiSummary < HelpdeskApplicationRecord
  belongs_to :issue
  belongs_to :journal, :optional => true

  validates :issue, :presence => true

  def total_tokens
    (input_tokens.to_i + output_tokens.to_i) if input_tokens || output_tokens
  end
end
