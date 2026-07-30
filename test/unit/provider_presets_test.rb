require File.expand_path('../../test_helper', __FILE__)

class ProviderPresetsTest < ActiveSupport::TestCase
  Presets = RedmineExpertHelpdesk::ProviderPresets

  def test_unknown_preset_falls_back_to_generic
    assert_equal Presets['generic'], Presets['does-not-exist']
  end

  def test_tenant_interpolation
    assert_equal 'https://login.microsoftonline.com/abc-123/oauth2/v2.0/token',
                 Presets.url('microsoft', :token_url, 'abc-123')
  end

  def test_tenant_defaults_to_common
    assert_includes Presets.url('microsoft', :authorize_url, nil), '/common/'
  end

  def test_scope_depends_on_grant
    assert_equal 'https://outlook.office365.com/.default',
                 Presets.scope('microsoft', 'client_credentials')
    assert_includes Presets.scope('microsoft', 'authorization_code'), 'IMAP.AccessAsUser.All'
  end

  # Google only issues a refresh token with these parameters.
  def test_google_requests_offline_access
    params = Presets.extra_authorize_params('google')
    assert_equal 'offline', params['access_type']
    assert_equal 'consent', params['prompt']
  end

  def test_defaults_omit_blank_values
    defaults = Presets.defaults_for('generic', 'client_credentials')
    assert_not defaults.key?(:imap_host)
    assert_equal 993, defaults[:imap_port]
  end

  def test_preset_never_overwrites_existing_values
    mailbox = HelpdeskMailbox.new(:provider => 'imap', :oauth_preset => 'microsoft',
                                  :imap_host => 'mail.internal.example', :imap_port => 1993)
    mailbox.apply_preset!
    assert_equal 'mail.internal.example', mailbox.imap_host
    assert_equal 1993, mailbox.imap_port
    assert_equal 'smtp.office365.com', mailbox.smtp_host
  end
end
