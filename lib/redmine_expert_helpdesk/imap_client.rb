# IMAP client for the generic mail provider.
#
# net/imap ships as a runtime dependency of the mail gem that Redmine already
# bundles, so no extra gem is required.
#
# Rules that keep this correct across servers:
#   * UIDs everywhere (uid_search/uid_fetch/uid_store/uid_move). Sequence
#     numbers shift under concurrent mailbox activity.
#   * BODY.PEEK[...] never BODY[...] - the latter silently sets \Seen and would
#     break the "unseen only" mode.
#   * Folder names travel over the wire in modified UTF-7 and with the server's
#     own hierarchy delimiter; the DB stores human-readable UTF-8 with '/'.
#   * MOVE (RFC 6851) when advertised, otherwise COPY + \Deleted + EXPUNGE.
require 'net/imap'
require 'timeout'

module RedmineExpertHelpdesk
  class ImapClient
    OPEN_TIMEOUT = 15
    FOLDER_CACHE_TTL = 12.hours

    class ImapError < MailProvider::ProviderError; end

    attr_reader :mailbox

    def initialize(mailbox, credentials = nil, token_provider = nil)
      @mailbox = mailbox
      @credentials = credentials || MailboxCredentials.for(mailbox)
      @token_provider = token_provider || OauthTokenProvider.new(mailbox, @credentials)
      @imap = nil
      @selected = nil
    end

    def configured?
      return false if @mailbox.imap_host.blank?

      if @credentials.auth_method == 'password'
        @credentials.password.present?
      else
        @token_provider.configured?
      end
    end

    # Opens one connection for the duration of the block. Nested calls reuse the
    # open connection, so callers can use it freely.
    def with_session
      return yield self if @imap

      begin
        Timeout.timeout(timeout_seconds) do
          open
          yield self
        end
      ensure
        close
      end
    end

    def open
      @imap = connect
      authenticate!
      @imap
    end

    # A timed-out or errored connection must never be reused - Timeout can
    # interrupt a blocking socket read and leave the protocol out of sync.
    def close
      return nil unless @imap

      begin
        @imap.logout
      rescue StandardError
        nil
      end
      begin
        @imap.disconnect unless @imap.disconnected?
      rescue StandardError
        nil
      end
      @imap = nil
      @selected = nil
    end

    # --- Messages --------------------------------------------------------------

    # Returns UIDs of the source folder, oldest first, capped at limit.
    def search_uids(folder, limit)
      select(folder)
      criteria = @mailbox.imap_unseen_only? ? %w[UNSEEN] : %w[ALL]
      uids = wrap { @imap.uid_search(criteria) } || []
      uids.sort.first(limit)
    end

    # One round trip for all metadata. The header block is parsed by the mail
    # gem, which handles RFC-2047 decoding.
    def fetch_headers(uids)
      return [] if uids.empty?

      items = ['UID', 'INTERNALDATE', 'BODY.PEEK[HEADER.FIELDS (SUBJECT FROM MESSAGE-ID DATE)]']
      Array(wrap { @imap.uid_fetch(uids, items) })
    end

    def fetch_mime(uid)
      data = Array(wrap { @imap.uid_fetch(Integer(uid), ['BODY.PEEK[]']) }).first
      raise ImapError, "Message #{uid} not found" unless data

      # RFC-conformant servers answer a BODY.PEEK[] request with BODY[];
      # some older ones answer with RFC822.
      raw = data.attr['BODY[]'] || data.attr['RFC822'] || data.attr['BODY.PEEK[]']
      raw.to_s.dup.force_encoding(Encoding::BINARY)
    end

    def mark_as_read(uid)
      select(@mailbox.source_folder)
      wrap { @imap.uid_store(Integer(uid), '+FLAGS', [:Seen]) }
      nil
    end

    def move(uid, folder_name)
      select(@mailbox.source_folder)
      target = find_or_create_folder(folder_name)
      uid = Integer(uid)

      if capability?('MOVE')
        wrap { @imap.uid_move(uid, target) }
      else
        wrap { @imap.uid_copy(uid, target) }
        wrap { @imap.uid_store(uid, '+FLAGS', [:Deleted]) }
        expunge(uid)
      end
      nil
    end

    # --- Folders ---------------------------------------------------------------

    # Human-readable '/'-delimited paths.
    def list_folders
      wrap { @imap.list('', '*') }.to_a
                                  .reject { |m| m.attr.include?(:Noselect) }
                                  .map { |m| to_display(m.name) }
                                  .sort
    end

    def create_folder(name)
      wrap { @imap.create(to_wire(name)) }
      bust_folder_cache
      name
    rescue ImapError => e
      # Racing with another process, or the folder was created between our LIST
      # and CREATE. Both are success for our purposes.
      raise unless e.message =~ /alreadyexists|already exists/i

      name
    end

    # Returns the wire-encoded folder name, ready to be passed to COPY/MOVE.
    def find_or_create_folder(name)
      wire = to_wire(name)
      return wire if known_folders.include?(name)

      create_folder(name)
      wire
    end

    def select(folder)
      wire = to_wire(folder.presence || 'INBOX')
      return if @selected == wire

      wrap { @imap.select(wire) }
      @selected = wire
    end

    def capability?(name)
      @capabilities ||= wrap { @imap.capability }.to_a.map(&:upcase)
      @capabilities.include?(name.to_s.upcase)
    end

    # Server's hierarchy delimiter ('/' for Dovecot and Gmail, '.' for Courier).
    def delimiter
      @delimiter ||= begin
        list = wrap { @imap.list('', '') }
        (list && list.first && list.first.delim) || '/'
      end
    end

    private

    def connect
      opts = { :port => port, :ssl => ssl_options }
      opts[:open_timeout] = OPEN_TIMEOUT

      begin
        Net::IMAP.new(@mailbox.imap_host, **opts)
      rescue ArgumentError
        # Very old net-imap versions don't accept :open_timeout.
        opts.delete(:open_timeout)
        Net::IMAP.new(@mailbox.imap_host, **opts)
      end.tap do |imap|
        imap.starttls(ssl_context) if security == 'starttls'
      end
    rescue Net::IMAP::Error, IOError, SocketError, OpenSSL::SSL::SSLError,
           Timeout::Error, SystemCallError => e
      raise ImapError, "IMAP #{@mailbox.imap_host}:#{port}: #{e.message}"
    end

    def authenticate!
      if @credentials.auth_method == 'password'
        wrap(MailProvider::AuthenticationError) do
          @imap.login(@credentials.username, @credentials.password)
        end
      else
        authenticate_xoauth2!
      end
    end

    # A cached token can have been revoked server-side; drop it and retry once
    # before giving up.
    def authenticate_xoauth2!
      attempt = 0
      begin
        attempt += 1
        xoauth2(@credentials.username, @token_provider.access_token)
      rescue Net::IMAP::NoResponseError, Net::IMAP::BadResponseError => e
        if attempt == 1
          @token_provider.invalidate!
          retry
        end
        raise MailProvider::AuthenticationError,
              "#{I18n.t(:error_helpdesk_imap_auth_failed)}: #{e.message}"
      end
    end

    def xoauth2(user, token)
      @imap.authenticate('XOAUTH2', user, token)
    rescue ArgumentError, NoMethodError, NameError
      # net-imap 0.3+ registers Net::IMAP::XOauth2Authenticator itself; older
      # versions need our own. Net::IMAP::SASL is 0.4+ and must not be used.
      register_xoauth2_authenticator
      @imap.authenticate('XOAUTH2', user, token)
    end

    def register_xoauth2_authenticator
      return if Net::IMAP.respond_to?(:authenticators) &&
                Net::IMAP.authenticators.key?('XOAUTH2')

      Net::IMAP.add_authenticator('XOAUTH2', Xoauth2Authenticator)
    rescue StandardError
      nil
    end

    # SASL XOAUTH2 initial client response.
    class Xoauth2Authenticator
      def initialize(user, token, **_options)
        @user = user
        @token = token
      end

      def process(_data)
        Xoauth2.sasl_string(@user, @token)
      end

      # net-imap 0.4+ SASL protocol
      def initial_response?
        true
      end
    end

    def security
      @mailbox.imap_security.presence || 'ssl'
    end

    def port
      (@mailbox.imap_port.presence || (security == 'ssl' ? 993 : 143)).to_i
    end

    def ssl_options
      return false unless security == 'ssl'

      ssl_context
    end

    def ssl_context
      if @mailbox.imap_verify_ssl == false
        Rails.logger.warn("[helpdesk] IMAP certificate verification disabled for #{@mailbox.mailbox_address}")
        { :verify_mode => OpenSSL::SSL::VERIFY_NONE }
      else
        { :verify_mode => OpenSSL::SSL::VERIFY_PEER }
      end
    end

    def timeout_seconds
      (@mailbox.imap_timeout.presence || 120).to_i
    end

    # net-imap has no read timeout of its own, so the session is wrapped in
    # Timeout at with_session level; per-command failures are translated here.
    def wrap(error_class = ImapError)
      yield
    rescue Net::IMAP::Error, IOError, SocketError, OpenSSL::SSL::SSLError,
           Timeout::Error, SystemCallError => e
      raise error_class, "IMAP #{@mailbox.imap_host}: #{e.message}"
    end

    def expunge(uid)
      if capability?('UIDPLUS')
        wrap { @imap.uid_expunge(uid) }
      else
        # Without UIDPLUS, EXPUNGE removes every \Deleted message in the folder,
        # not just ours. Nothing else in this plugin sets \Deleted, but a mail
        # client on the same mailbox might have.
        Rails.logger.warn(
          "[helpdesk] #{@mailbox.mailbox_address}: server has neither MOVE nor UIDPLUS; " \
          'EXPUNGE will also remove other messages flagged \\Deleted in ' \
          "#{@mailbox.source_folder}"
        )
        wrap { @imap.expunge }
      end
    end

    # --- Folder name translation ----------------------------------------------

    # 'Verarbeitet/2026' -> wire encoding with the server delimiter, modified UTF-7
    def to_wire(name)
      path = name.to_s.split('/').join(delimiter)
      encode_utf7(path)
    end

    def to_display(wire_name)
      decode_utf7(wire_name.to_s).split(delimiter).join('/')
    end

    def encode_utf7(value)
      Net::IMAP.respond_to?(:encode_utf7) ? Net::IMAP.encode_utf7(value) : value
    end

    def decode_utf7(value)
      Net::IMAP.respond_to?(:decode_utf7) ? Net::IMAP.decode_utf7(value) : value
    end

    def known_folders
      Rails.cache.fetch(folder_cache_key, :expires_in => FOLDER_CACHE_TTL) { list_folders }
    end

    def bust_folder_cache
      Rails.cache.delete(folder_cache_key)
    end

    def folder_cache_key
      "redmine_expert_helpdesk/imap_folders/#{@mailbox.id}"
    end
  end
end
