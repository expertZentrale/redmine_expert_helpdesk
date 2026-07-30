# Connection presets for the IMAP/SMTP provider.
#
# Presets only prefill blank fields — an explicit value entered by the operator
# is never overwritten. They are applied both client-side (form JS) and
# server-side (HelpdeskMailbox#apply_preset!), so mailboxes created through the
# API get the same defaults.
module RedmineExpertHelpdesk
  module ProviderPresets
    PRESETS = {
      'microsoft' => {
        :imap_host     => 'outlook.office365.com',
        :imap_port     => 993,
        :imap_security => 'ssl',
        :smtp_host     => 'smtp.office365.com',
        :smtp_port     => 587,
        :smtp_security => 'starttls',
        :authorize_url => 'https://login.microsoftonline.com/{tenant}/oauth2/v2.0/authorize',
        :token_url     => 'https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token',
        :scopes        => {
          # App-only access needs the tenant to grant IMAP.AccessAsApp /
          # SMTP.SendAsApp; the SASL user is the mailbox address, not the app.
          'client_credentials' => 'https://outlook.office365.com/.default',
          'authorization_code' => 'https://outlook.office.com/IMAP.AccessAsUser.All ' \
                                  'https://outlook.office.com/SMTP.Send offline_access'
        }
      },
      'google' => {
        :imap_host     => 'imap.gmail.com',
        :imap_port     => 993,
        :imap_security => 'ssl',
        :smtp_host     => 'smtp.gmail.com',
        :smtp_port     => 587,
        :smtp_security => 'starttls',
        :authorize_url => 'https://accounts.google.com/o/oauth2/v2/auth',
        :token_url     => 'https://oauth2.googleapis.com/token',
        :scopes        => {
          'authorization_code' => 'https://mail.google.com/',
          'jwt_bearer'         => 'https://mail.google.com/'
        },
        # Google only issues a refresh token with these two parameters present.
        :extra_authorize_params => { 'access_type' => 'offline', 'prompt' => 'consent' }
      },
      'generic' => {
        :imap_port     => 993,
        :imap_security => 'ssl',
        :smtp_port     => 587,
        :smtp_security => 'starttls',
        :scopes        => {}
      }
    }.freeze

    NAMES = PRESETS.keys.freeze

    class << self
      def [](name)
        PRESETS[name.to_s] || PRESETS['generic']
      end

      def known?(name)
        PRESETS.key?(name.to_s)
      end

      # Interpolates {tenant} in authorize/token URLs.
      def url(preset_name, key, tenant_id = nil)
        raw = self[preset_name][key]
        return nil if raw.blank?

        raw.sub('{tenant}', tenant_id.presence || 'common')
      end

      def scope(preset_name, grant)
        self[preset_name][:scopes][grant.to_s]
      end

      def extra_authorize_params(preset_name)
        self[preset_name][:extra_authorize_params] || {}
      end

      # Values a mailbox should inherit from its preset, limited to the given
      # grant. Only used to fill blanks.
      def defaults_for(preset_name, grant, tenant_id = nil)
        p = self[preset_name]
        {
          :imap_host           => p[:imap_host],
          :imap_port           => p[:imap_port],
          :imap_security       => p[:imap_security],
          :smtp_host           => p[:smtp_host],
          :smtp_port           => p[:smtp_port],
          :smtp_security       => p[:smtp_security],
          :oauth_authorize_url => url(preset_name, :authorize_url, tenant_id),
          :oauth_token_url     => url(preset_name, :token_url, tenant_id),
          :oauth_scope         => scope(preset_name, grant)
        }.reject { |_k, v| v.blank? }
      end
    end
  end
end
