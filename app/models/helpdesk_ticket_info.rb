# Autoritative Zuordnung Ticket -> Kunde/Ursprungspostfach (eine Zeile pro Ticket).
# Wird beim ersten Mail-Eingang, beim manuellen Zuordnen (Init) und beim
# Legacy-Import gesetzt. Ersetzt die fruehere Konvention "Kontakt der ersten
# HelpdeskMessage = Kunde des Tickets".
class HelpdeskTicketInfo < HelpdeskApplicationRecord
  belongs_to :issue
  belongs_to :helpdesk_contact, :optional => true
  belongs_to :helpdesk_mailbox, :optional => true

  validates :issue_id, :presence => true, :uniqueness => true

  # Why the ticket is waiting: a plain customer reply, or an auto-reopen.
  AWAITING_REASONS = %w(reply reopen).freeze

  scope :awaiting_agent, -> { where.not(:awaiting_agent_since => nil) }

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

  # Marks a ticket as waiting for an agent. `since` is only set when the ticket is
  # not already waiting, so a second unanswered reply does not reset the waiting
  # age. The reason is upgraded to 'reopen' whenever a mail reopened the ticket,
  # because that is the more urgent story.
  # Never raises: the mail ingest must not fail because of this flag.
  def self.mark_awaiting_agent!(issue, reason, at = Time.current)
    reason = 'reply' unless AWAITING_REASONS.include?(reason)
    info = find_or_initialize_by(:issue_id => issue.id)
    info.awaiting_agent_since = at if info.awaiting_agent_since.nil?
    info.awaiting_agent_reason = reason if reason == 'reopen' || info.awaiting_agent_reason.blank?
    info.save! if info.changed?
    info
  rescue StandardError => e
    Rails.logger.warn("Helpdesk: mark_awaiting_agent! failed (issue ##{issue.try(:id)}): #{e.message}")
    nil
  end

  # Clears the flag. Deliberately uses find_by + update_columns: it must not create
  # a row just to clear it, and it must not re-trigger the Issue callbacks.
  def self.clear_awaiting_agent!(issue)
    info = for_issue(issue)
    return nil if info.nil? || info.awaiting_agent_since.nil?

    info.update_columns(:awaiting_agent_since => nil, :awaiting_agent_reason => nil)
    info
  rescue StandardError => e
    Rails.logger.warn("Helpdesk: clear_awaiting_agent! failed (issue ##{issue.try(:id)}): #{e.message}")
    nil
  end
end
