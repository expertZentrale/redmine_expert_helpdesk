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

  def test_effective_reply_transport
    assert_equal 'graph', HelpdeskMailbox.new(:reply_transport => 'provider').effective_reply_transport
    assert_equal 'mailbox_smtp',
                 HelpdeskMailbox.new(:provider => 'imap', :reply_transport => 'provider').effective_reply_transport
    assert_equal 'smtp', HelpdeskMailbox.new(:reply_transport => 'smtp').effective_reply_transport
    assert_equal 'graph', HelpdeskMailbox.new(:reply_transport => 'graph').effective_reply_transport
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
end
