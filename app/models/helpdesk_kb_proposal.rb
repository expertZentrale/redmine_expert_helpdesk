# Ein Loesungsvorschlag fuer ein Ticket, ermittelt aus einem aehnlichen geloesten
# Ticket (RAG). Wird bei der Zusammenfassung erzeugt und in der Seitenleiste
# angezeigt. source_issue = das aehnliche, bereits geloeste Ticket.
class HelpdeskKbProposal < HelpdeskApplicationRecord
  belongs_to :issue,        :optional => true
  belongs_to :source_issue, :class_name => 'Issue', :optional => true

  validates :issue_id, :presence => true
end
