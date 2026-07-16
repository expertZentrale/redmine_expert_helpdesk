# Postfach-Konfiguration eines Projekts.
# Jedes Projekt kann ein oder mehrere O365-Postfaecher haben, deren Mails
# als Tickets in diesem Projekt verarbeitet werden.
class HelpdeskMailbox < HelpdeskApplicationRecord
  include Redmine::SafeAttributes

  belongs_to :project
  belongs_to :default_tracker,  :class_name => 'Tracker',       :optional => true
  belongs_to :default_priority, :class_name => 'IssuePriority', :optional => true
  belongs_to :default_status,   :class_name => 'IssueStatus',   :optional => true
  belongs_to :reopen_status,    :class_name => 'IssueStatus',   :optional => true
  has_many :helpdesk_rules, :dependent => :destroy
  has_many :helpdesk_messages, :dependent => :nullify

  UNKNOWN_USER_MODES = %w[accept create ignore].freeze

  # Kombination der Postfach-Fusszeile mit der zentralen Signatur:
  #   inherit  - zentrale Signatur (Fallback: Postfach-Fusszeile, solange keine zentrale gepflegt ist)
  #   prepend  - Postfach-Fusszeile VOR der zentralen Signatur
  #   override - nur die Postfach-Fusszeile
  FOOTER_MODES = %w[inherit prepend override].freeze

  validates :mailbox_address, :presence => true, :uniqueness => true,
            :format => { :with => /\A[^@\s]+@[^@\s]+\z/, :message => :invalid }
  validates :project, :presence => true
  validates :unknown_user_mode, :inclusion => { :in => UNKNOWN_USER_MODES }, :allow_blank => true
  validates :footer_mode, :inclusion => { :in => FOOTER_MODES }, :allow_blank => true

  scope :enabled, -> { where(:enabled => true) }

  after_initialize :set_defaults, :if => :new_record?

  safe_attributes 'mailbox_address', 'source_folder', 'processed_folder', 'enabled',
                  'default_tracker_id', 'default_priority_id', 'default_status_id',
                  'unknown_user_mode', 'suppress_notifications',
                  'allow_list', 'deny_list',
                  'autoresponder_enabled', 'autoresponder_subject', 'autoresponder_body',
                  'reply_header', 'reply_footer', 'reply_transport', 'footer_mode',
                  'auto_reply_filter_enabled', 'auto_reply_sender_whitelist',
                  'auto_reply_header_whitelist',
                  'skipped_folder', 'failed_folder',
                  'reopen_status_id', 'reopen_max_age_days'

  # Effektive Fusszeilen-Vorlage (unrendered, Makros noch enthalten):
  # kombiniert Postfach-Fusszeile und zentrale Signatur gemaess footer_mode.
  def effective_footer_template
    global = Setting.plugin_redmine_expert_helpdesk['global_footer'].to_s

    case footer_mode.presence || 'inherit'
    when 'override'
      reply_footer.to_s
    when 'prepend'
      [reply_footer.presence, global.presence].compact.join("\n\n")
    else # inherit
      # Fallback auf die Postfach-Fusszeile, solange keine zentrale Signatur gepflegt ist
      global.presence || reply_footer.to_s
    end
  end

  private

  def set_defaults
    self.autoresponder_subject ||= '[#{{ticket_id}}] {{ticket_subject}}'
    self.autoresponder_body    ||= "Sehr geehrte/r {{contact_name}},\n\n" \
                                   "vielen Dank fuer Ihre Nachricht. Wir haben Ihre Anfrage erhalten " \
                                   "und werden uns schnellstmoeglich darum kuemmern.\n\n" \
                                   "Ihre Ticket-Nummer: \#{{ticket_id}}\n" \
                                   "Betreff: {{ticket_subject}}\n\n" \
                                   "Mit freundlichen Gruessen\n" \
                                   "{{project_name}}"
    self.reply_footer          ||= "--\n{{project_name}}"
  end
end
