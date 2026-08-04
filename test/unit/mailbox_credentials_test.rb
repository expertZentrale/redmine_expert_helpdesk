require File.expand_path('../../test_helper', __FILE__)

class MailboxCredentialsTest < ActiveSupport::TestCase
  Resolver = RedmineExpertHelpdesk::MailboxCredentials

  # There is exactly one central application registration; the settings form
  # offers no second copy of it.
  SETTINGS = {
    'tenant_id'            => 'central-tenant',
    'client_id'            => 'central-client',
    'client_secret'        => 'central-secret',
    'default_oauth_preset' => 'microsoft',
    'default_oauth_grant'  => 'client_credentials'
  }.freeze

  def test_global_source_reads_plugin_settings
    mailbox = HelpdeskMailbox.new(:mailbox_address => 'hd@example.com', :credentials_source => 'global')
    creds = Resolver.for(mailbox, SETTINGS)
    assert_equal 'central-client', creds.client_id
    assert_equal 'central-secret', creds.client_secret
    assert_equal 'central-tenant', creds.tenant_id
    assert_includes creds.token_url, 'central-tenant'
  end

  # Graph mailboxes configured before this feature existed must keep working:
  # they never had anything but these three keys.
  def test_global_source_uses_the_graph_keys_unchanged
    creds = Resolver.for(HelpdeskMailbox.new(:mailbox_address => 'hd@example.com'), SETTINGS)
    assert_equal 'central-client', creds.client_id
    assert_equal 'central-secret', creds.client_secret
    assert_equal 'central-tenant', creds.tenant_id
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
