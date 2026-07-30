require File.expand_path('../../test_helper', __FILE__)

class OauthTokenProviderTest < ActiveSupport::TestCase
  Provider = RedmineExpertHelpdesk::OAuthTokenProvider

  # Overrides the single network seam; everything else is the real code.
  class StubbedProvider < Provider
    attr_reader :requests

    def initialize(mailbox, credentials, response)
      super(mailbox, credentials)
      @response = response
      @requests = []
    end

    private

    def post_form(url, params)
      @requests << [url, params]
      raise @response if @response.is_a?(Exception)

      @response
    end
  end

  def setup
    Rails.cache.clear
    @mailbox = HelpdeskMailbox.new(:id => 4711, :mailbox_address => 'hd@example.com')
  end

  def test_client_credentials_request
    provider = StubbedProvider.new(@mailbox, credentials, 'access_token' => 'T1', 'expires_in' => 3600)
    assert_equal 'T1', provider.access_token
    _url, params = provider.requests.first
    assert_equal 'client_credentials', params['grant_type']
    assert_equal 'cid', params['client_id']
  end

  def test_token_is_cached_until_shortly_before_expiry
    provider = StubbedProvider.new(@mailbox, credentials, 'access_token' => 'T1', 'expires_in' => 3600)
    provider.access_token
    provider.access_token
    assert_equal 1, provider.requests.size
  end

  # Rotating a secret must take effect immediately, not after the cached token
  # expires - hence the credential fingerprint in the cache key.
  def test_cache_key_changes_with_credentials
    first = StubbedProvider.new(@mailbox, credentials, 'access_token' => 'T1', 'expires_in' => 3600)
    first.access_token

    rotated = credentials
    rotated.client_secret = 'new-secret'
    second = StubbedProvider.new(@mailbox, rotated, 'access_token' => 'T2', 'expires_in' => 3600)
    assert_equal 'T2', second.access_token
    assert_equal 1, second.requests.size
  end

  def test_invalidate_forces_a_new_request
    provider = StubbedProvider.new(@mailbox, credentials, 'access_token' => 'T1', 'expires_in' => 3600)
    provider.access_token
    provider.invalidate!
    provider.access_token
    assert_equal 2, provider.requests.size
  end

  def test_missing_token_in_response_raises
    provider = StubbedProvider.new(@mailbox, credentials, 'expires_in' => 3600)
    assert_raise(Provider::TokenError) { provider.access_token }
  end

  def test_unconfigured_credentials_raise
    creds = credentials
    creds.client_secret = nil
    provider = StubbedProvider.new(@mailbox, creds, {})
    assert_not provider.configured?
    assert_raise(RedmineExpertHelpdesk::MailProvider::ConfigurationError) { provider.access_token }
  end

  def test_jwt_bearer_builds_a_signed_assertion
    creds = credentials
    creds.grant = 'jwt_bearer'
    creds.sa_email = 'svc@project.iam.gserviceaccount.com'
    creds.sa_key = OpenSSL::PKey::RSA.new(2048).to_pem
    creds.scope = 'https://mail.google.com/'

    provider = StubbedProvider.new(@mailbox, creds, 'access_token' => 'T1', 'expires_in' => 3600)
    assert_equal 'T1', provider.access_token

    _url, params = provider.requests.first
    assert_equal 'urn:ietf:params:oauth:grant-type:jwt-bearer', params['grant_type']

    header, claims, signature = params['assertion'].split('.')
    assert_equal 'RS256', JSON.parse(Base64.urlsafe_decode64(pad(header)))['alg']
    parsed = JSON.parse(Base64.urlsafe_decode64(pad(claims)))
    assert_equal 'svc@project.iam.gserviceaccount.com', parsed['iss']
    # sub impersonates the mailbox - this is what domain-wide delegation grants.
    assert_equal 'hd@example.com', parsed['sub']
    assert parsed['exp'] > parsed['iat']
    assert signature.present?
  end

  private

  def pad(segment)
    segment + '=' * ((4 - segment.length % 4) % 4)
  end

  def credentials
    RedmineExpertHelpdesk::Credentials.new(
      :grant         => 'client_credentials',
      :auth_method   => 'oauth2',
      :client_id     => 'cid',
      :client_secret => 'csecret',
      :tenant_id     => 'tenant',
      :token_url     => 'https://login.example.com/oauth2/v2.0/token',
      :scope         => 'https://outlook.office365.com/.default'
    )
  end
end
