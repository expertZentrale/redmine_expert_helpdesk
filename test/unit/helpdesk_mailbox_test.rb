require File.expand_path('../../test_helper', __FILE__)

# Tests fuer die Fusszeilen-Logik (zentrale Signatur vs. Postfach-Fusszeile).
class HelpdeskMailboxTest < ActiveSupport::TestCase
  GLOBAL = "--\nexample.com Zentrale".freeze
  LOCAL  = "Team Nord\nTel. 0123".freeze

  def setup
    @previous_settings = Setting.plugin_redmine_expert_helpdesk
  end

  def teardown
    Setting.plugin_redmine_expert_helpdesk = @previous_settings
  end

  def test_inherit_uses_global_footer
    set_global_footer(GLOBAL)
    mailbox = HelpdeskMailbox.new(:footer_mode => 'inherit', :reply_footer => LOCAL)
    assert_equal GLOBAL, mailbox.effective_footer_template
  end

  def test_inherit_falls_back_to_mailbox_footer_without_global
    set_global_footer('')
    mailbox = HelpdeskMailbox.new(:footer_mode => 'inherit', :reply_footer => LOCAL)
    assert_equal LOCAL, mailbox.effective_footer_template
  end

  def test_blank_mode_behaves_like_inherit
    set_global_footer(GLOBAL)
    mailbox = HelpdeskMailbox.new(:footer_mode => nil, :reply_footer => LOCAL)
    assert_equal GLOBAL, mailbox.effective_footer_template
  end

  def test_override_uses_mailbox_footer_only
    set_global_footer(GLOBAL)
    mailbox = HelpdeskMailbox.new(:footer_mode => 'override', :reply_footer => LOCAL)
    assert_equal LOCAL, mailbox.effective_footer_template
  end

  def test_prepend_combines_mailbox_and_global
    set_global_footer(GLOBAL)
    mailbox = HelpdeskMailbox.new(:footer_mode => 'prepend', :reply_footer => LOCAL)
    assert_equal "#{LOCAL}\n\n#{GLOBAL}", mailbox.effective_footer_template
  end

  def test_prepend_with_blank_mailbox_footer_uses_global_only
    set_global_footer(GLOBAL)
    mailbox = HelpdeskMailbox.new(:footer_mode => 'prepend', :reply_footer => '')
    assert_equal GLOBAL, mailbox.effective_footer_template
  end

  def test_footer_mode_validation
    mailbox = HelpdeskMailbox.new(:footer_mode => 'kaputt')
    mailbox.valid?
    assert_not_empty mailbox.errors[:footer_mode]

    HelpdeskMailbox::FOOTER_MODES.each do |mode|
      mailbox = HelpdeskMailbox.new(:footer_mode => mode)
      mailbox.valid?
      assert_empty mailbox.errors[:footer_mode], "#{mode} sollte gueltig sein"
    end
  end

  # --- Provider / IMAP ------------------------------------------------------

  def test_provider_defaults_to_graph
    assert_equal 'graph', HelpdeskMailbox.new.provider
    assert HelpdeskMailbox.new.graph?
    assert_not HelpdeskMailbox.new.imap?
  end

  def test_new_records_default_to_the_own_backend_for_replies
    assert_equal 'provider', HelpdeskMailbox.new.reply_transport
    assert_equal 'global', HelpdeskMailbox.new.credentials_source
  end

  def test_enum_validations
    {
      :provider           => %w[graph imap],
      :credentials_source => %w[global mailbox],
      :auth_method        => %w[oauth2 password],
      :oauth_grant        => %w[client_credentials authorization_code jwt_bearer],
      :imap_security      => %w[ssl starttls plain],
      :reply_transport    => %w[provider graph smtp]
    }.each do |attribute, allowed|
      mailbox = HelpdeskMailbox.new(attribute => 'kaputt')
      mailbox.valid?
      assert_not_empty mailbox.errors[attribute], "#{attribute} sollte ungueltig sein"

      allowed.each do |value|
        mailbox = HelpdeskMailbox.new(attribute => value)
        mailbox.valid?
        assert_empty mailbox.errors[attribute], "#{attribute}=#{value} sollte gueltig sein"
      end
    end
  end

  def test_imap_requires_a_host
    mailbox = HelpdeskMailbox.new(:provider => 'imap', :oauth_preset => 'generic')
    mailbox.valid?
    assert_not_empty mailbox.errors[:imap_host]
  end

  # The global host/port settings only earn their place if the self-hosted case
  # can actually be configured centrally.
  def test_generic_preset_falls_back_to_the_global_connection_defaults
    with_settings_hash('default_imap_host' => 'mail.example.com', 'default_imap_port' => '143',
                       'default_imap_security' => 'starttls', 'default_smtp_host' => 'mail.example.com') do
      mailbox = HelpdeskMailbox.new(:provider => 'imap', :oauth_preset => 'generic')
      mailbox.valid?
      assert_equal 'mail.example.com', mailbox.imap_host
      assert_equal 143, mailbox.imap_port.to_i
      assert_equal 'starttls', mailbox.imap_security
      assert_equal 'mail.example.com', mailbox.smtp_host
    end
  end

  # A named preset states facts, so it must not be overridden by a global default
  # left over from some other server.
  def test_named_preset_outranks_the_global_connection_defaults
    with_settings_hash('default_imap_host' => 'mail.example.com') do
      mailbox = HelpdeskMailbox.new(:provider => 'imap', :oauth_preset => 'microsoft')
      mailbox.valid?
      assert_equal 'outlook.office365.com', mailbox.imap_host
    end
  end

  def test_explicit_host_beats_every_default
    with_settings_hash('default_imap_host' => 'mail.example.com') do
      mailbox = HelpdeskMailbox.new(:provider => 'imap', :oauth_preset => 'generic',
                                    :imap_host => 'own.example.org')
      mailbox.valid?
      assert_equal 'own.example.org', mailbox.imap_host
    end
  end

  # --- Outgoing route --------------------------------------------------------
  # Outgoing mail has to leave through the account that owns mailbox_address,
  # otherwise the thread with the customer comes apart.

  def test_outgoing_route_for_every_provider_and_transport
    assert_equal 'graph', HelpdeskMailbox.new(:reply_transport => 'provider').outgoing_route
    assert_equal 'mailbox_smtp',
                 HelpdeskMailbox.new(:provider => 'imap', :reply_transport => 'provider').outgoing_route
    assert_equal 'smtp', HelpdeskMailbox.new(:reply_transport => 'smtp').outgoing_route
    assert_equal 'smtp',
                 HelpdeskMailbox.new(:provider => 'imap', :reply_transport => 'smtp').outgoing_route
    assert_equal 'graph', HelpdeskMailbox.new(:reply_transport => 'graph').outgoing_route
    assert_equal 'graph',
                 HelpdeskMailbox.new(:provider => 'imap', :reply_transport => 'graph').outgoing_route
  end

  def test_graph_transport_is_unavailable_for_a_non_microsoft_mailbox
    mailbox = imap_mailbox(:oauth_preset => 'google', :reply_transport => 'graph')

    assert_not mailbox.valid?
    assert_includes mailbox.errors.attribute_names, :reply_transport
    assert_not_includes mailbox.available_reply_transports, 'graph'
  end

  # "Microsoft 365 over IMAP" is a real setup, and there Graph is a legitimate
  # sender for a mailbox fetched over IMAP.
  def test_graph_transport_is_available_for_microsoft_over_imap
    mailbox = imap_mailbox(:oauth_preset => 'microsoft', :reply_transport => 'graph')

    assert_includes mailbox.available_reply_transports, 'graph'
    assert mailbox.valid?, mailbox.errors.full_messages.join(', ')
  end

  # Rows written before this rule existed store 'graph' on a Graph mailbox.
  def test_existing_graph_mailboxes_keep_validating
    mailbox = HelpdeskMailbox.new(:mailbox_address => 'hd@example.com', :reply_transport => 'graph')

    assert mailbox.microsoft_hosted?
    assert_equal %w[provider graph smtp], mailbox.available_reply_transports
    assert mailbox.valid?, mailbox.errors.full_messages.join(', ')
  end

  # An IMAP mailbox on the Redmine relay needs no SMTP server of its own.
  def test_relay_transport_does_not_require_an_smtp_host
    mailbox = imap_mailbox(:oauth_preset => 'generic', :reply_transport => 'smtp', :smtp_host => nil)

    assert mailbox.valid?, mailbox.errors.full_messages.join(', ')
  end

  # --- Secrets ---------------------------------------------------------------

  def test_secrets_are_stored_encrypted
    mailbox = HelpdeskMailbox.new
    mailbox.mail_password = 'geheim'
    assert_not_equal 'geheim', mailbox.mail_password_enc
    assert_equal 'geheim', mailbox.mail_password
  end

  # The masked form field submits blank on every save; that must not wipe the
  # stored secret.
  def test_blank_secret_keeps_the_stored_value
    mailbox = HelpdeskMailbox.new
    mailbox.oauth_client_secret = 'geheim'
    mailbox.oauth_client_secret = ''
    assert_equal 'geheim', mailbox.oauth_client_secret

    mailbox.oauth_client_secret = nil
    assert_equal 'geheim', mailbox.oauth_client_secret
  end

  def test_explicit_marker_clears_a_secret
    mailbox = HelpdeskMailbox.new
    mailbox.oauth_client_secret = 'geheim'
    mailbox.oauth_client_secret = HelpdeskMailbox::CLEAR_SECRET
    assert_nil mailbox.oauth_client_secret_enc
  end

  def test_oauth_connected_only_matters_for_the_consent_flow
    assert HelpdeskMailbox.new.oauth_connected?
    assert HelpdeskMailbox.new(:provider => 'imap', :auth_method => 'password').oauth_connected?

    pending = HelpdeskMailbox.new(:provider => 'imap', :auth_method => 'oauth2',
                                  :oauth_grant => 'authorization_code')
    assert_not pending.oauth_connected?

    pending.oauth_refresh_token = 'rt'
    assert pending.oauth_connected?
  end

  private

  def set_global_footer(value)
    Setting.plugin_redmine_expert_helpdesk =
      (Setting.plugin_redmine_expert_helpdesk || {}).merge('global_footer' => value)
  end

  def imap_mailbox(attrs = {})
    HelpdeskMailbox.new({ :mailbox_address => 'hd@example.com',
                          :provider        => 'imap',
                          :imap_host       => 'imap.example.com',
                          :smtp_host       => 'smtp.example.com' }.merge(attrs))
  end

  def with_settings_hash(overrides)
    previous = Setting.plugin_redmine_expert_helpdesk
    Setting.plugin_redmine_expert_helpdesk = (previous || {}).merge(overrides)
    yield
  ensure
    Setting.plugin_redmine_expert_helpdesk = previous
  end
end
