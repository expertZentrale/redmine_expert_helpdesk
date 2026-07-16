# Autoritative Zuordnung Ticket -> Kunde/Ursprungspostfach (eine Zeile pro Ticket).
# Wird beim ersten Mail-Eingang, beim manuellen Zuordnen (Init) und beim
# Legacy-Import gesetzt. Ersetzt die fruehere Konvention "Kontakt der ersten
# HelpdeskMessage = Kunde des Tickets".
class HelpdeskTicketInfo < HelpdeskApplicationRecord
  belongs_to :issue
  belongs_to :helpdesk_contact, :optional => true
  belongs_to :helpdesk_mailbox, :optional => true

  validates :issue_id, :presence => true, :uniqueness => true

  def self.for_issue(issue)
    find_by(:issue_id => issue.is_a?(Issue) ? issue.id : issue)
  end

  # Setzt Kunde/Ursprungspostfach eines Tickets. Bereits gesetzte Werte werden
  # nicht ueberschrieben (der Erstkontakt bleibt der Kunde des Tickets).
  def self.link!(issue, contact, mailbox = nil)
    info = find_or_initialize_by(:issue_id => issue.id)
    info.helpdesk_contact ||= contact
    info.helpdesk_mailbox ||= mailbox
    info.save! if info.changed?
    info
  end
end
