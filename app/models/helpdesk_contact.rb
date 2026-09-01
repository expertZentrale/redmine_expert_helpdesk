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

  safe_attributes 'name', 'company', 'phone', 'notes'

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

  # Tickets, zu denen Nachrichten dieses Kontakts existieren
  def issues
    Issue.where(:id => helpdesk_messages.select(:issue_id)).distinct
  end
end
