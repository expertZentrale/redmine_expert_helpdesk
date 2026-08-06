# Mailbox configuration of a project.
# A project can have one or more mailboxes whose mail is turned into tickets in
# that project. The backend is selected per mailbox via #provider: Microsoft 365
# (Graph API) or generic IMAP/SMTP.
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

  # Mail backend of this mailbox.
  PROVIDERS = %w[graph imap].freeze

  # Where credentials come from. A mailbox uses one source entirely - blank
  # fields are never backfilled from the other source, because a half-filled
  # mailbox silently authenticating against the wrong tenant is the failure
  # mode that makes two sources of truth unsupportable.
  CREDENTIAL_SOURCES = %w[global mailbox].freeze

  AUTH_METHODS = %w[oauth2 password].freeze

  #   client_credentials - app-only, no user interaction (Microsoft IMAP)
  #   authorization_code - one interactive consent, refresh token stored
  #   jwt_bearer         - signed assertion (Google service account with DWD)
  OAUTH_GRANTS = %w[client_credentials authorization_code jwt_bearer].freeze

  SECURITY_MODES = %w[ssl starttls plain].freeze

  # How this mailbox sends. Outgoing mail has to come from the account that owns
  # mailbox_address, otherwise the conversation with the customer falls apart, so
  # not every value is available to every mailbox - see #available_reply_transports.
  #   provider - the mailbox's own backend (Graph API resp. its SMTP server)
  #   graph    - Microsoft Graph via the central registration; only meaningful
  #              for a mailbox that actually lives in Microsoft 365
  #   smtp     - Redmine's global ActionMailer SMTP configuration
  REPLY_TRANSPORTS = %w[provider graph smtp].freeze

  # Submitting this marker in a secret field clears the stored value; a blank
  # field keeps it (see #assign_secret).
  CLEAR_SECRET = '-'.freeze

  validates :mailbox_address, :presence => true, :uniqueness => true,
            :format => { :with => /\A[^@\s]+@[^@\s]+\z/, :message => :invalid }
  validates :project, :presence => true
  validates :unknown_user_mode, :inclusion => { :in => UNKNOWN_USER_MODES }, :allow_blank => true
  validates :footer_mode, :inclusion => { :in => FOOTER_MODES }, :allow_blank => true
  validates :provider, :inclusion => { :in => PROVIDERS }, :allow_blank => true
  validates :credentials_source, :inclusion => { :in => CREDENTIAL_SOURCES }, :allow_blank => true
  validates :auth_method, :inclusion => { :in => AUTH_METHODS }, :allow_blank => true
  validates :oauth_grant, :inclusion => { :in => OAUTH_GRANTS }, :allow_blank => true
  validates :oauth_preset, :inclusion => { :in => RedmineExpertHelpdesk::ProviderPresets::NAMES }, :allow_blank => true
  validates :imap_security, :inclusion => { :in => SECURITY_MODES }, :allow_blank => true
  validates :smtp_security, :inclusion => { :in => SECURITY_MODES }, :allow_blank => true
  # Validated against what this mailbox can actually do, not just the full list:
  # pointing a Gmail or Dovecot mailbox at Graph produced a 404 at send time.
  # A Proc, not a symbol: a symbol would be looked up under the ActiveRecord
  # error scope, and not resolved at class-definition time when no locale is set.
  validates :reply_transport,
            :inclusion => { :in => ->(mailbox) { mailbox.available_reply_transports },
                            :message => ->(_object, _data) {
                              I18n.t(:error_helpdesk_transport_not_available)
                            } },
            :allow_blank => true
  validates :imap_host, :presence => true, :if => :imap?
  validates :smtp_host, :presence => true, :if => -> { imap? && outgoing_route == 'mailbox_smtp' }

  scope :enabled, -> { where(:enabled => true) }

  before_validation :apply_preset!, :if => :imap?

  after_initialize :set_defaults, :if => :new_record?

  safe_attributes 'mailbox_address', 'source_folder', 'processed_folder', 'enabled',
                  'default_tracker_id', 'default_priority_id', 'default_status_id',
                  'unknown_user_mode', 'suppress_notifications',
                  'allow_list', 'deny_list',
                  'autoresponder_enabled', 'autoresponder_subject', 'autoresponder_body',
                  'reply_header', 'reply_footer', 'reply_transport', 'footer_mode',
                  'auto_reply_filter_enabled', 'auto_reply_sender_whitelist',
                  'auto_reply_header_whitelist',
                  'skipped_folder', 'failed_folder', 'sent_folder',
                  'reopen_status_id', 'reopen_max_age_days',
                  'provider', 'credentials_source', 'auth_method',
                  'imap_host', 'imap_port', 'imap_security', 'imap_username',
                  'imap_verify_ssl', 'imap_unseen_only', 'imap_timeout',
                  'smtp_host', 'smtp_port', 'smtp_security', 'smtp_username',
                  'smtp_verify_ssl',
                  'oauth_preset', 'oauth_grant', 'oauth_tenant_id', 'oauth_client_id',
                  'oauth_authorize_url', 'oauth_token_url', 'oauth_scope', 'oauth_sa_email',
                  # virtual writers below; the *_enc columns are never safe attributes
                  'mail_password', 'oauth_client_secret', 'oauth_sa_key'

  def provider
    super.presence || 'graph'
  end

  def imap?
    provider == 'imap'
  end

  def graph?
    provider == 'graph'
  end

  # --- Encrypted secrets -----------------------------------------------------
  # A blank submission keeps the stored value, so the masked password fields in
  # the form don't wipe secrets on every save.

  def mail_password
    RedmineExpertHelpdesk::SecretBox.decrypt_safe(mail_password_enc)
  end

  def mail_password=(value)
    assign_secret(:mail_password_enc, value)
  end

  def oauth_client_secret
    RedmineExpertHelpdesk::SecretBox.decrypt_safe(oauth_client_secret_enc)
  end

  def oauth_client_secret=(value)
    assign_secret(:oauth_client_secret_enc, value)
  end

  def oauth_sa_key
    RedmineExpertHelpdesk::SecretBox.decrypt_safe(oauth_sa_key_enc)
  end

  def oauth_sa_key=(value)
    assign_secret(:oauth_sa_key_enc, value)
  end

  def oauth_refresh_token
    RedmineExpertHelpdesk::SecretBox.decrypt_safe(oauth_refresh_token_enc)
  end

  def oauth_refresh_token=(value)
    self.oauth_refresh_token_enc =
      value.blank? ? nil : RedmineExpertHelpdesk::SecretBox.encrypt(value)
  end

  # --- Transport -------------------------------------------------------------

  # Resolves the stored transport into the concrete route every outgoing mail
  # takes - replies, initial mails and the autoresponder alike, which is why
  # this is not called "reply" anything:
  #   graph        - Microsoft Graph sendMail
  #   mailbox_smtp - this mailbox's own SMTP server
  #   smtp         - Redmine's global ActionMailer SMTP settings
  def outgoing_route
    t = reply_transport.presence || 'graph'
    return t unless t == 'provider'

    imap? ? 'mailbox_smtp' : 'graph'
  end

  # Graph can only send for a mailbox that Microsoft actually hosts. That is
  # every 'graph' mailbox, plus an IMAP mailbox on the Microsoft preset - the
  # "Microsoft 365 over IMAP" setup, where Graph is a legitimate outgoing route
  # and files the Sent copy for free.
  #
  # Judged by the preset that is in EFFECT, not by the oauth_preset column: a
  # mailbox on global credentials follows the plugin settings, so the column is
  # either blank (nothing backfills it - the API can leave it empty) or stale
  # from an earlier configuration. Reading it decided this question with a value
  # nobody was using.
  def microsoft_hosted?
    graph? || (imap? && RedmineExpertHelpdesk::MailboxCredentials.preset_for(self) == 'microsoft')
  end

  # Being hosted by Microsoft is not enough - the central app registration has to
  # exist, otherwise 'graph' is a route that only fails at send time. A 'graph'
  # mailbox is exempt: its own backend is Graph either way, and demanding
  # credentials here would make it unsavable while the Azure app is still being
  # set up.
  def graph_transport_available?
    return true if graph?

    microsoft_hosted? && RedmineExpertHelpdesk::GraphClient.new.configured?
  end

  # The transports this mailbox may actually use. Drives the form select and the
  # validation, so an unusable combination cannot be stored in the first place.
  def available_reply_transports
    REPLY_TRANSPORTS.reject { |t| t == 'graph' && !graph_transport_available? }
  end

  # True unless an interactive OAuth consent is still outstanding.
  def oauth_connected?
    return true unless imap? && auth_method == 'oauth2'
    return true unless oauth_grant == 'authorization_code'

    oauth_refresh_token_enc.present?
  end

  # Fills blank connection fields from the selected preset. Never overwrites a
  # value the operator entered.
  def apply_preset!
    preset_defaults = RedmineExpertHelpdesk::ProviderPresets.defaults_for(
      oauth_preset, oauth_grant, oauth_tenant_id
    )
    # A named preset states facts (outlook.office365.com is not a guess), so it
    # outranks the global defaults. The 'generic' preset only guesses ports and
    # has no host at all - there the operator's global defaults are the better
    # answer, which is what makes those settings worth having.
    defaults = if oauth_preset.to_s == 'generic'
                 preset_defaults.merge(global_connection_defaults)
               else
                 global_connection_defaults.merge(preset_defaults)
               end

    defaults.each do |attr, value|
      send("#{attr}=", value) if self[attr].blank?
    end
  end

  # Host/port/encryption an operator running one mail server centrally can set
  # once instead of repeating on every mailbox.
  def global_connection_defaults
    settings = Setting.plugin_redmine_expert_helpdesk
    {
      :imap_host     => settings['default_imap_host'],
      :imap_port     => settings['default_imap_port'],
      :imap_security => settings['default_imap_security'],
      :smtp_host     => settings['default_smtp_host'],
      :smtp_port     => settings['default_smtp_port'],
      :smtp_security => settings['default_smtp_security']
    }.reject { |_k, v| v.blank? }
  end

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

    # New mailboxes default to their own backend for outgoing mail. Existing
    # rows are untouched (after_initialize runs for new records only).
    self.provider           ||= 'graph'
    self.reply_transport    ||= 'provider'
    self.credentials_source ||= 'global'
  end

  # Blank means "keep what is stored" so the masked form fields don't wipe
  # secrets. Pass an explicit empty marker to clear a secret.
  def assign_secret(column, value)
    return if value.nil?

    str = value.to_s
    return if str.empty?

    self[column] = (str == CLEAR_SECRET ? nil : RedmineExpertHelpdesk::SecretBox.encrypt(str))
  end
end
