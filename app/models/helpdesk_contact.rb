# Kunde/Kontakt: wird automatisch aus dem Mail-Absender angelegt
# und mit Tickets verknuepft (Kundeninfo-Panel auf der Ticketseite).
# Kontakte sind Projekt-spezifisch: jedes Projekt pflegt seine eigene
# Kundenliste mit eigenen Metadaten (Firma, Telefon, Notizen usw.).
class HelpdeskContact < HelpdeskApplicationRecord
  include Redmine::SafeAttributes

  belongs_to :project, :optional => true
  has_many :helpdesk_messages, :dependent => :nullify
  # Nullify like the messages: without it a destroyed contact leaves a
  # dangling helpdesk_contact_id behind (the customer columns/filter guard
  # against legacy dangling rows, but new ones should not be created).
  has_many :helpdesk_ticket_infos, :dependent => :nullify

  validates :email, :presence => true
  validates :email, :uniqueness => { :scope => :project_id, :case_sensitive => false }

  # info_request_opt_out marks a sender nobody could answer a follow-up for (Veeam
  # job report, cron mail, monitoring alert). HelpdeskCompletenessJob reads it in
  # both modes, next to the project-wide info_request_sender_blacklist.
  safe_attributes 'name', 'company', 'phone', 'notes', 'info_request_opt_out'

  # Sucht oder erstellt einen Kontakt fuer die angegebene E-Mail-Adresse
  # im Kontext des angegebenen Projekts.
  def self.find_or_create_for(email, name = nil, project = nil)
    email = email.to_s.downcase.strip
    scope = project ? where(:project_id => project.id) : where(:project_id => nil)
    contact = scope.where('LOWER(email) = ?', email).first
    contact ||= create!(:email => email, :name => name.presence, :project => project)
    # Name nachtragen, falls bisher unbekannt
    contact.update_column(:name, name) if contact.name.blank? && name.present?
    contact
  end

  def display_name
    name.presence || email
  end

  # Tickets of this contact: those with a mail of theirs, and those linked to
  # them without one yet - a hand-over creates the ticket and the contact link
  # directly, and the customer only writes later, if at all.
  #
  # Only tickets +user+ may see: a handed-over ticket can move on to a project
  # the viewer has no access to, and the history would otherwise show its
  # subject and status.
  def issues(user = User.current)
    Issue.visible(user)
         .where(:id => helpdesk_messages.select(:issue_id))
         .or(Issue.visible(user).where(:id => helpdesk_ticket_infos.select(:issue_id)))
         .distinct
  end

  # "Last ticket" in the customer list: the later of the contact's last mail
  # and the creation of the newest ticket linked to them - a hand-over ticket
  # has no mail yet. The list passes +newest_linked+ from one grouped query
  # for the whole page instead of loading every linked ticket;
  # HelpdeskContactsController::LAST_TICKET_SQL sorts by the same rule.
  def last_ticket_at(newest_linked = newest_linked_ticket_at)
    [helpdesk_messages.map(&:sent_at).compact.max, newest_linked].compact.max
  end

  def newest_linked_ticket_at
    Issue.where(:id => helpdesk_ticket_infos.select(:issue_id)).maximum(:created_on)
  end
end
