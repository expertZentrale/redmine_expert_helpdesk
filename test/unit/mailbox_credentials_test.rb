require File.expand_path('../../test_helper', __FILE__)

class MailboxCredentialsTest < ActiveSupport::TestCase
  Resolver = RedmineExpertHelpdesk::MailboxCredentials

  SETTINGS = {
    'tenant_id'                   => 'legacy-tenant',
    'client_id'                   => 'legacy-client',
    'client_secret'               => 'legacy-secret',
    'default_oauth_preset'        => 'microsoft',
    'default_oauth_grant'         => 'client_credentials',
    'default_oauth_tenant_id'     => 'global-tenant',
    'default_oauth_client_id'     => 'global-client',
    'default_oauth_client_secret' => 'global-secret'
  }.freeze

  def test_global_source_reads_plugin_settings
    mailbox = HelpdeskMailbox.new(:mailbox_address => 'hd@example.com', :credentials_source => 'global')
    creds = Resolver.for(mailbox, SETTINGS)
    assert_equal 'global-client', creds.client_id
    assert_equal 'global-secret', creds.client_secret
    assert_equal 'global-tenant', creds.tenant_id
    assert_includes creds.token_url, 'global-tenant'
  end

  # Graph mailboxes configured before this feature existed must keep working.
  def test_global_source_falls_back_to_legacy_graph_keys
    settings = SETTINGS.merge('default_oauth_client_id' => '', 'default_oauth_client_secret' => '',
                              'default_oauth_tenant_id' => '')
    creds = Resolver.for(HelpdeskMailbox.new(:mailbox_address => 'hd@example.com'), settings)
    assert_equal 'legacy-client', creds.client_id
    assert_equal 'legacy-secret', creds.client_secret
    assert_equal 'legacy-tenant', creds.tenant_id
  end

  def test_mailbox_source_reads_own_columns
    mailbox = HelpdeskMailbox.new(
      :mailbox_address    => 'hd@example.com',
      :credentials_source => 'mailbox',
      :oauth_client_id    => 'own-client',
      :oauth_tenant_id    => 'own-tenant'
    )
    mailbox.oauth_client_secret = 'own-secret'

    creds = Resolver.for(mailbox, SETTINGS)
    assert_equal 'own-client', creds.client_id
    assert_equal 'own-secret', creds.client_secret
    assert_equal 'own-tenant', creds.tenant_id
  end

  # The whole point of the enum: a blank per-mailbox field must NOT silently
  # fall back to the global app registration.
  def test_mailbox_source_does_not_mix_in_global_values
    mailbox = HelpdeskMailbox.new(:mailbox_address => 'hd@example.com',
                                  :credentials_source => 'mailbox')
    creds = Resolver.for(mailbox, SETTINGS)
    assert_nil creds.client_id.presence
    assert_nil creds.client_secret.presence
  end

  def test_username_defaults_to_mailbox_address
    mailbox = HelpdeskMailbox.new(:mailbox_address => 'hd@example.com')
    assert_equal 'hd@example.com', Resolver.for(mailbox, SETTINGS).username

    mailbox.imap_username = 'service-account'
    assert_equal 'service-account', Resolver.for(mailbox, SETTINGS).username
  end
end
