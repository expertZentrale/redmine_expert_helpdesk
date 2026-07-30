# SMTP sender for IMAP/SMTP mailboxes.
#
# Unlike the 'smtp' reply transport (which uses Redmine's global ActionMailer
# settings), this sends through the mailbox's own server with its own
# credentials, so a project can have mailboxes on different providers.
require 'net/smtp'
require 'mail'

module RedmineExpertHelpdesk
  class SmtpSender
    OPEN_TIMEOUT = 15
    READ_TIMEOUT = 60

    class SmtpError < MailProvider::ProviderError; end

    def initialize(mailbox, credentials = nil, token_provider = nil)
      @mailbox = mailbox
      @credentials = credentials || MailboxCredentials.for(mailbox)
      @token_provider = token_provider || OauthTokenProvider.new(mailbox, @credentials)
    end

    def configured?
      return false if @mailbox.smtp_host.blank?

      if @credentials.auth_method == 'password'
        @credentials.password.present?
      else
        @token_provider.configured?
      end
    end

    def send_mime(mime_string)
      mail = Mail.read_from_string(mime_string)
      recipients = envelope_recipients(mail)
      raise SmtpError, I18n.t(:error_helpdesk_no_recipient) if recipients.empty?

      deliver(strip_bcc(mail).to_s, recipients)
      nil
    end

    def test_connection
      return { :ok => false, :message => I18n.t(:error_helpdesk_provider_not_configured) } unless configured?

      start { |_smtp| nil }
      { :ok => true, :message => I18n.t(:notice_helpdesk_connection_ok) }
    rescue StandardError => e
      { :ok => false, :message => e.message }
    end

    private

    def deliver(body, recipients)
      start do |smtp|
        smtp.send_message(body, @mailbox.mailbox_address, recipients)
      end
    end

    def start
      smtp = Net::SMTP.new(@mailbox.smtp_host, port)
      smtp.open_timeout = OPEN_TIMEOUT
      smtp.read_timeout = READ_TIMEOUT

      case security
      when 'ssl'      then smtp.enable_tls(ssl_context)
      when 'starttls' then smtp.enable_starttls(ssl_context)
      end

      # No user/secret passed to #start, so net/smtp skips its own AUTH and we
      # drive authentication ourselves.
      smtp.start(helo_domain) do |session|
        authenticate(session)
        yield session
      end
    rescue Net::SMTPAuthenticationError => e
      raise MailProvider::AuthenticationError,
            "#{I18n.t(:error_helpdesk_smtp_auth_failed)}: #{e.message}"
    rescue Net::SMTPError, IOError, SocketError, OpenSSL::SSL::SSLError,
           Timeout::Error, SystemCallError => e
      raise SmtpError, "SMTP #{@mailbox.smtp_host}:#{port}: #{e.message}"
    end

    def authenticate(smtp)
      if @credentials.auth_method == 'password'
        authenticate_password(smtp)
      else
        authenticate_xoauth2(smtp)
      end
    end

    # Simple servers disagree about which SASL mechanism they offer: Dovecot and
    # Postfix advertise PLAIN, some hosters only LOGIN, older setups only
    # CRAM-MD5. Pinning one mechanism made every server that lacked it fail with
    # an authentication error that looked like wrong credentials, so ask the
    # server what it takes and use the first one both sides know.
    PASSWORD_MECHANISMS = [:plain, :login, :cram_md5].freeze

    def authenticate_password(smtp)
      mechanism = supported_mechanism(smtp)
      raise MailProvider::AuthenticationError, I18n.t(:error_helpdesk_smtp_no_auth_mechanism) unless mechanism

      smtp.authenticate(username, @credentials.password, mechanism)
    end

    def supported_mechanism(smtp)
      # An unauthenticated EHLO already told us; if the server advertised
      # nothing, try PLAIN rather than give up without an attempt.
      # auth_capable? wants the SASL name ('PLAIN', 'CRAM-MD5') and returns nil
      # while the capabilities are unknown - then the select yields nothing and
      # the caller falls back to PLAIN.
      offered = PASSWORD_MECHANISMS.select do |m|
        smtp.respond_to?(:auth_capable?) ? smtp.auth_capable?(m.to_s.tr('_', '-').upcase) : true
      end
      offered.first || :plain
    rescue StandardError
      :plain
    end

    # A cached token can have been revoked; drop it and retry once.
    def authenticate_xoauth2(smtp)
      attempt = 0
      begin
        attempt += 1
        SmtpXoauth2.authenticate(smtp, username, @token_provider.access_token)
      rescue MailProvider::AuthenticationError
        if attempt == 1
          @token_provider.invalidate!
          retry
        end
        raise
      end
    end

    def username
      @mailbox.smtp_username.presence || @credentials.username
    end

    def security
      @mailbox.smtp_security.presence || 'starttls'
    end

    def port
      (@mailbox.smtp_port.presence || (security == 'ssl' ? 465 : 587)).to_i
    end

    def ssl_context
      context = OpenSSL::SSL::SSLContext.new
      if @mailbox.smtp_verify_ssl == false
        Rails.logger.warn("[helpdesk] SMTP certificate verification disabled for #{@mailbox.mailbox_address}")
        context.verify_mode = OpenSSL::SSL::VERIFY_NONE
      else
        context.verify_mode = OpenSSL::SSL::VERIFY_PEER
        context.cert_store = OpenSSL::X509::Store.new.tap(&:set_default_paths)
      end
      context
    end

    def helo_domain
      Setting.plugin_redmine_expert_helpdesk['smtp_helo_domain'].presence ||
        Setting.host_name.to_s.split(':').first.presence ||
        'localhost'
    end

    # Bcc has to travel in the SMTP envelope only. Graph/Exchange strips the
    # header for us; a real SMTP server does not, so leaving it in place would
    # expose blind recipients to everyone.
    def envelope_recipients(mail)
      (Array(mail.to) + Array(mail.cc) + Array(mail.bcc)).map(&:to_s).uniq
    end

    def strip_bcc(mail)
      mail.bcc = nil if mail.bcc.present?
      mail
    end
  end

  # net/smtp has no stable public XOAUTH2 API across the Ruby versions this
  # plugin supports (Redmine 5.1 -> 7.0 spans net-smtp 0.3 and 0.4+), so the
  # three known shapes are tried in order.
  module SmtpXoauth2
    class << self
      def authenticate(smtp, user, token)
        if native?(smtp)
          smtp.authenticate(user, token, :xoauth2)
        elsif authenticator_registry?
          register_authenticator
          smtp.authenticate(user, token, :xoauth2)
        else
          legacy_authenticate(smtp, user, token)
        end
      end

      private

      # A future net-smtp shipping XOAUTH2 out of the box.
      def native?(smtp)
        smtp.respond_to?(:auth_xoauth2, true)
      end

      # net-smtp >= 0.4 (Ruby 3.3+, Redmine 7)
      def authenticator_registry?
        defined?(::Net::SMTP::Authenticator) && ::Net::SMTP.respond_to?(:add_authenticator)
      end

      def register_authenticator
        return if defined?(@registered) && @registered

        klass = Class.new(::Net::SMTP::Authenticator) do
          auth_type :xoauth2

          def auth(user, token)
            finish("AUTH XOAUTH2 #{RedmineExpertHelpdesk::Xoauth2.encoded(user, token)}")
          end
        end
        ::Net::SMTP.const_set(:HelpdeskXoauth2Authenticator, klass) unless
          ::Net::SMTP.const_defined?(:HelpdeskXoauth2Authenticator)
        @registered = true
      end

      # net-smtp 0.3.x (Ruby 3.0-3.2) - the common case on Redmine 5.1/6.0.
      # #critical and #get_response are private but stable across the 0.3 line.
      def legacy_authenticate(smtp, user, token)
        command = "AUTH XOAUTH2 #{Xoauth2.encoded(user, token)}"
        response = smtp.send(:critical) { smtp.send(:get_response, command) }

        return if response.success?

        # On rejection the server sends a 334 challenge holding a base64 JSON
        # error. The client must send an empty line to complete the exchange,
        # otherwise the session hangs waiting for one.
        if response.status.to_s.start_with?('334')
          details = Xoauth2.decode_challenge(response.string.to_s.split(' ').last)
          smtp.send(:critical) { smtp.send(:get_response, '') }
          raise MailProvider::AuthenticationError,
                "#{I18n.t(:error_helpdesk_smtp_auth_failed)}: #{details.inspect}"
        end

        raise MailProvider::AuthenticationError,
              "#{I18n.t(:error_helpdesk_smtp_auth_failed)}: #{response.message}"
      end
    end
  end
end
