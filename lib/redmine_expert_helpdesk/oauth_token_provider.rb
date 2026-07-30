# OAuth2 access tokens for IMAP/SMTP mailboxes.
#
# Net::HTTP only, mirroring GraphClient#access_token. Three grants:
#
#   client_credentials - app-only. Microsoft needs the tenant to grant
#                        IMAP.AccessAsApp / SMTP.SendAsApp; the SASL user is
#                        the mailbox address, not the app.
#   authorization_code - refresh token obtained once via ExpertHelpdeskOauthController
#                        and stored encrypted on the mailbox.
#   jwt_bearer         - signed assertion for a Google service account with
#                        domain-wide delegation. Signed with OpenSSL, so no
#                        jwt/googleauth gem is needed.
require 'net/http'
require 'uri'
require 'json'
require 'base64'
require 'digest'
require 'openssl'

module RedmineExpertHelpdesk
  class OauthTokenProvider
    CACHE_PREFIX = 'redmine_expert_helpdesk/oauth_token'.freeze
    OPEN_TIMEOUT = 15
    READ_TIMEOUT = 60

    # Assertion lifetime for the jwt_bearer grant. Google rejects anything
    # above one hour.
    ASSERTION_TTL = 3600

    class TokenError < MailProvider::AuthenticationError; end

    def initialize(mailbox, credentials = nil)
      @mailbox = mailbox
      @credentials = credentials || MailboxCredentials.for(mailbox)
    end

    def configured?
      return false if @credentials.token_url.blank?

      case grant
      when 'authorization_code'
        @credentials.client_id.present? && @credentials.refresh_token.present?
      when 'jwt_bearer'
        @credentials.sa_email.present? && @credentials.sa_key.present?
      else
        @credentials.client_id.present? && @credentials.client_secret.present?
      end
    end

    def access_token
      cached = Rails.cache.read(cache_key)
      return cached if cached

      unless configured?
        raise MailProvider::ConfigurationError,
              I18n.t(:error_helpdesk_provider_not_configured)
      end

      body = request_token
      token = body['access_token'].to_s
      raise TokenError, I18n.t(:error_helpdesk_oauth_token_failed) if token.empty?

      ttl = [body['expires_in'].to_i - 120, 60].max
      Rails.cache.write(cache_key, token, :expires_in => ttl.seconds)
      token
    end

    # Drops the cached token. Called once before retrying an authentication that
    # failed, to cover server-side revocation.
    def invalidate!
      Rails.cache.delete(cache_key)
      nil
    end

    private

    def grant
      @credentials.grant.presence || 'client_credentials'
    end

    # Changing any credential changes the key, so a rotated secret takes effect
    # immediately instead of after the cached token expires.
    def cache_key
      fingerprint = Digest::SHA256.hexdigest(
        [@credentials.client_id, @credentials.tenant_id, @credentials.token_url,
         @credentials.scope, grant].join('|')
      )[0, 12]
      "#{CACHE_PREFIX}/#{@mailbox.id}/#{fingerprint}"
    end

    def request_token
      case grant
      when 'authorization_code' then refresh_access_token
      when 'jwt_bearer'         then jwt_bearer_token
      else                           client_credentials_token
      end
    end

    def client_credentials_token
      post_form(@credentials.token_url,
                'grant_type'    => 'client_credentials',
                'client_id'     => @credentials.client_id,
                'client_secret' => @credentials.client_secret,
                'scope'         => @credentials.scope)
    end

    # Some identity providers rotate the refresh token on every use. The lock
    # keeps two concurrent fetch_all runs from invalidating each other's token.
    def refresh_access_token
      @mailbox.with_lock do
        body = post_form(@credentials.token_url,
                         'grant_type'    => 'refresh_token',
                         'refresh_token' => @credentials.refresh_token,
                         'client_id'     => @credentials.client_id,
                         'client_secret' => @credentials.client_secret,
                         'scope'         => @credentials.scope)

        if body['refresh_token'].present? && body['refresh_token'] != @credentials.refresh_token
          @mailbox.oauth_refresh_token = body['refresh_token']
          @mailbox.update_column(:oauth_refresh_token_enc, @mailbox.oauth_refresh_token_enc)
          @credentials.refresh_token = body['refresh_token']
        end

        if body['expires_in'].present?
          @mailbox.update_column(:oauth_token_expires_at, Time.now + body['expires_in'].to_i)
        end

        body
      end
    end

    def jwt_bearer_token
      post_form(@credentials.token_url,
                'grant_type' => 'urn:ietf:params:oauth:grant-type:jwt-bearer',
                'assertion'  => build_assertion)
    end

    # RS256-signed JWT for a Google service account. "sub" impersonates the
    # mailbox, which requires domain-wide delegation for the configured scope.
    def build_assertion
      now = Time.now.to_i
      header = { 'alg' => 'RS256', 'typ' => 'JWT' }
      claims = {
        'iss'   => @credentials.sa_email,
        'sub'   => @mailbox.mailbox_address,
        'scope' => @credentials.scope,
        'aud'   => @credentials.token_url,
        'iat'   => now,
        'exp'   => now + ASSERTION_TTL
      }

      signing_input = [header, claims].map { |part| b64url(JSON.generate(part)) }.join('.')
      key = OpenSSL::PKey::RSA.new(@credentials.sa_key.to_s)
      signature = key.sign(OpenSSL::Digest::SHA256.new, signing_input)
      "#{signing_input}.#{b64url(signature)}"
    rescue OpenSSL::PKey::RSAError => e
      raise MailProvider::ConfigurationError, "Service account key invalid: #{e.message}"
    end

    def b64url(value)
      Base64.urlsafe_encode64(value).delete('=')
    end

    # Single seam for tests to stub out the network.
    def post_form(url, params)
      uri = URI(url.to_s)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = uri.scheme == 'https'
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT

      request = Net::HTTP::Post.new(uri.request_uri)
      request.set_form_data(params.reject { |_k, v| v.blank? })
      response = http.request(request)

      parsed = begin
        JSON.parse(response.body.to_s)
      rescue JSON::ParserError
        {}
      end

      return parsed if response.is_a?(Net::HTTPSuccess)

      handle_error(parsed, response)
    rescue Timeout::Error, Errno::ECONNREFUSED, Errno::ECONNRESET, SocketError, OpenSSL::SSL::SSLError => e
      raise TokenError, "#{uri.host}: #{e.message}"
    end

    # A revoked or expired refresh token can only be fixed by a new consent, so
    # clear it and surface the reconnect hint instead of retrying forever.
    def handle_error(parsed, response)
      code = parsed['error'].to_s
      description = parsed['error_description'].presence || response.body.to_s[0, 300]

      if code == 'invalid_grant' && grant == 'authorization_code'
        @mailbox.update_columns(:oauth_refresh_token_enc => nil,
                                :last_error => I18n.t(:error_helpdesk_oauth_reauth_required),
                                :last_error_at => Time.now)
        raise TokenError.new(I18n.t(:error_helpdesk_oauth_reauth_required),
                             response.code.to_i, description)
      end

      raise TokenError.new("#{I18n.t(:error_helpdesk_oauth_token_failed)}: #{code} #{description}".strip,
                           response.code.to_i, description)
    end
  end
end
