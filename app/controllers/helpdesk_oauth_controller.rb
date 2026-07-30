# OAuth2 authorization-code flow for IMAP/SMTP mailboxes.
#
# The callback URL must be a single fixed path because identity providers only
# accept exactly registered redirect URIs. The mailbox therefore travels in a
# signed state parameter, not in the path.
require 'net/http'
require 'uri'
require 'json'

class HelpdeskOauthController < ApplicationController
  # The identity provider redirects here with a plain GET and no Redmine CSRF
  # token; the signed state parameter takes its place.
  skip_before_action :verify_authenticity_token, :only => [:callback]

  before_action :find_mailbox, :only => [:authorize]
  before_action :authorize_mailbox_management, :only => [:authorize]

  STATE_PURPOSE = 'helpdesk_oauth'.freeze
  STATE_TTL = 10.minutes

  def authorize
    credentials = RedmineExpertHelpdesk::MailboxCredentials.for(@mailbox)

    if credentials.authorize_url.blank? || credentials.client_id.blank?
      flash[:error] = l(:error_helpdesk_provider_not_configured)
      return redirect_to settings_project_path(@mailbox.project, :tab => 'expert_helpdesk')
    end

    redirect_to authorize_url(credentials), :allow_other_host => true
  end

  def callback
    state = verify_state(params[:state])
    return render_state_error unless state

    mailbox = HelpdeskMailbox.find_by(:id => state[:mailbox_id])
    return render_404 unless mailbox
    return render_403 unless User.current.allowed_to?(:manage_helpdesk, mailbox.project)

    if params[:error].present?
      flash[:error] = "#{l(:error_helpdesk_oauth_token_failed)}: #{params[:error_description].presence || params[:error]}"
      return redirect_to settings_project_path(mailbox.project, :tab => 'expert_helpdesk')
    end

    exchange_code(mailbox, params[:code].to_s)
    flash[:notice] = l(:notice_helpdesk_oauth_connected)
    redirect_to settings_project_path(mailbox.project, :tab => 'expert_helpdesk')
  rescue RedmineExpertHelpdesk::MailProvider::ProviderError => e
    flash[:error] = e.message
    redirect_to home_path
  end

  # The exact URI that has to be registered with the identity provider.
  def self.callback_url
    "#{Setting.protocol}://#{Setting.host_name}/helpdesk/oauth/callback"
  end

  private

  def authorize_url(credentials)
    params = {
      'response_type' => 'code',
      'client_id'     => credentials.client_id,
      'redirect_uri'  => self.class.callback_url,
      'scope'         => credentials.scope,
      'login_hint'    => @mailbox.mailbox_address,
      'state'         => generate_state(@mailbox)
    }.merge(RedmineExpertHelpdesk::ProviderPresets.extra_authorize_params(credentials.preset))

    uri = URI(credentials.authorize_url)
    existing = URI.decode_www_form(uri.query.to_s)
    uri.query = URI.encode_www_form(existing + params.reject { |_k, v| v.blank? }.to_a)
    uri.to_s
  end

  def exchange_code(mailbox, code)
    credentials = RedmineExpertHelpdesk::MailboxCredentials.for(mailbox)
    body = post_token(credentials.token_url,
                      'grant_type'    => 'authorization_code',
                      'code'          => code,
                      'redirect_uri'  => self.class.callback_url,
                      'client_id'     => credentials.client_id,
                      'client_secret' => credentials.client_secret)

    if body['refresh_token'].blank?
      raise RedmineExpertHelpdesk::MailProvider::AuthenticationError,
            l(:error_helpdesk_oauth_no_refresh_token)
    end

    mailbox.oauth_refresh_token = body['refresh_token']
    mailbox.update_columns(
      :oauth_refresh_token_enc => mailbox.oauth_refresh_token_enc,
      :oauth_connected_at      => Time.current,
      :oauth_token_expires_at  => body['expires_in'].present? ? Time.current + body['expires_in'].to_i : nil,
      :last_error              => nil,
      :last_error_at           => nil
    )
  end

  def post_token(url, params)
    uri = URI(url.to_s)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == 'https'
    http.open_timeout = 15
    http.read_timeout = 60

    request = Net::HTTP::Post.new(uri.request_uri)
    request.set_form_data(params.reject { |_k, v| v.blank? })
    response = http.request(request)
    parsed = JSON.parse(response.body.to_s) rescue {}

    unless response.is_a?(Net::HTTPSuccess)
      raise RedmineExpertHelpdesk::MailProvider::AuthenticationError,
            "#{l(:error_helpdesk_oauth_token_failed)}: #{parsed['error_description'].presence || response.code}"
    end

    parsed
  end

  # A signed, short-lived state defends the callback against CSRF and carries
  # the mailbox id, which cannot live in the fixed redirect path.
  def generate_state(mailbox)
    Rails.application.message_verifier(STATE_PURPOSE).generate(
      { :mailbox_id => mailbox.id, :nonce => SecureRandom.hex(16) },
      :expires_in => STATE_TTL
    )
  end

  def verify_state(value)
    return nil if value.blank?

    Rails.application.message_verifier(STATE_PURPOSE).verify(value)
  rescue ActiveSupport::MessageVerifier::InvalidSignature
    nil
  end

  def render_state_error
    render :plain => l(:error_helpdesk_oauth_state_invalid), :status => :bad_request
  end

  def find_mailbox
    @mailbox = HelpdeskMailbox.find_by(:id => params[:mailbox_id])
    render_404 unless @mailbox
  end

  def authorize_mailbox_management
    render_403 unless User.current.allowed_to?(:manage_helpdesk, @mailbox.project)
  end
end
