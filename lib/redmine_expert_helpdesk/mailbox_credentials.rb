# Resolves the effective credentials of a mailbox.
#
# Precedence rule (documented in the README): a mailbox uses EITHER the global
# plugin settings OR its own columns, never a mix. HelpdeskMailbox#credentials_source
# decides. Individual blank fields are deliberately NOT backfilled from the other
# source - a half-filled mailbox would otherwise silently authenticate against
# the wrong tenant.
#
# For provider == 'graph' with credentials_source == 'global' the behaviour is
# identical to before this abstraction existed.
module RedmineExpertHelpdesk
  Credentials = Struct.new(
    :preset, :grant, :auth_method,
    :client_id, :client_secret, :tenant_id,
    :authorize_url, :token_url, :scope,
    :username, :password, :refresh_token,
    :sa_email, :sa_key,
    :keyword_init => true
  )

  module MailboxCredentials
    class << self
      def for(mailbox, settings = nil)
        settings ||= Setting.plugin_redmine_expert_helpdesk
        mailbox.credentials_source == 'mailbox' ? from_mailbox(mailbox) : from_global(mailbox, settings)
      end

      private

      def from_mailbox(mailbox)
        Credentials.new(
          :preset        => mailbox.oauth_preset,
          :grant         => mailbox.oauth_grant,
          :auth_method   => mailbox.auth_method,
          :client_id     => mailbox.oauth_client_id,
          :client_secret => mailbox.oauth_client_secret,
          :tenant_id     => mailbox.oauth_tenant_id,
          :authorize_url => mailbox.oauth_authorize_url,
          :token_url     => mailbox.oauth_token_url,
          :scope         => mailbox.oauth_scope,
          :username      => login_username(mailbox),
          :password      => mailbox.mail_password,
          :refresh_token => mailbox.oauth_refresh_token,
          :sa_email      => mailbox.oauth_sa_email,
          :sa_key        => mailbox.oauth_sa_key
        )
      end

      def from_global(mailbox, settings)
        preset = settings['default_oauth_preset'].presence || 'microsoft'
        grant  = settings['default_oauth_grant'].presence || 'client_credentials'
        tenant = settings['default_oauth_tenant_id'].presence || settings['tenant_id']

        Credentials.new(
          :preset        => preset,
          :grant         => grant,
          :auth_method   => mailbox.auth_method,
          :client_id     => settings['default_oauth_client_id'].presence || settings['client_id'],
          :client_secret => settings['default_oauth_client_secret'].presence || settings['client_secret'],
          :tenant_id     => tenant,
          :authorize_url => settings['default_oauth_authorize_url'].presence ||
                            ProviderPresets.url(preset, :authorize_url, tenant),
          :token_url     => settings['default_oauth_token_url'].presence ||
                            ProviderPresets.url(preset, :token_url, tenant),
          :scope         => settings['default_oauth_scope'].presence ||
                            ProviderPresets.scope(preset, grant),
          :username      => login_username(mailbox),
          # Passwords are always per mailbox - a shared global mail password
          # would make no sense across different accounts.
          :password      => mailbox.mail_password,
          :refresh_token => mailbox.oauth_refresh_token,
          :sa_email      => mailbox.oauth_sa_email,
          :sa_key        => mailbox.oauth_sa_key
        )
      end

      def login_username(mailbox)
        mailbox.imap_username.presence || mailbox.mailbox_address
      end
    end
  end
end
