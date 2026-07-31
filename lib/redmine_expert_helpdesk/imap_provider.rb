# MailProvider implementation for generic IMAP/SMTP mailboxes.
#
# Covers Google Workspace, Exchange on-premises, self-hosted Dovecot/Zimbra and
# any hoster: incoming over IMAP, outgoing over the mailbox's own SMTP server.
require 'mail'

module RedmineExpertHelpdesk
  class ImapProvider
    attr_reader :mailbox

    def initialize(mailbox, imap_client = nil, smtp_sender = nil)
      @mailbox = mailbox
      credentials = MailboxCredentials.for(mailbox)
      @imap = imap_client || ImapClient.new(mailbox, credentials)
      @smtp = smtp_sender || SmtpSender.new(mailbox, credentials)
    end

    def configured?
      @imap.configured?
    end

    def list_messages(limit = 25)
      with_session do
        uids = @imap.search_uids(@mailbox.source_folder, limit)
        @imap.fetch_headers(uids).map { |data| to_meta(data) }.compact
      end
    end

    def message_mime(id)
      with_session { @imap.fetch_mime(id) }
    end

    def mark_as_read(id)
      with_session { @imap.mark_as_read(id) }
      nil
    end

    def move_message(id, folder_name)
      with_session { @imap.move(id, folder_name) }
      nil
    end

    def list_folders
      with_session { @imap.list_folders }
    end

    def create_folder(name)
      with_session { @imap.create_folder(name) }
    end

    def find_or_create_folder(name)
      with_session { @imap.find_or_create_folder(name) }
    end

    def send_mail_mime(mime_string)
      @smtp.send_mime(mime_string)
      archive_sent(mime_string)
      nil
    end

    # SMTP only hands the message to the next hop; nothing files it in the
    # mailbox the way Graph's sendMail does. Without this a shared helpdesk
    # mailbox shows the inbound half of every conversation and nothing else.
    #
    # Archiving must never cost us the mail itself: the customer has already
    # received it by the time we get here, so a failure is logged and swallowed.
    def archive_sent(mime_string)
      @imap.append_sent(mime_string)
      nil
    rescue StandardError => e
      Rails.logger.warn(
        "[helpdesk] #{I18n.t(:warning_helpdesk_sent_append_failed, :message => e.message)} " \
        "(#{@mailbox.mailbox_address})"
      )
      nil
    end

    def test_connection
      unless configured?
        return { :ok => false, :message => I18n.t(:error_helpdesk_provider_not_configured), :folders => [] }
      end

      folders = list_folders

      # Only probe the route this mailbox actually sends over. Reporting an SMTP
      # failure for a mailbox that sends via Redmine's relay, or staying silent
      # about Graph for one that sends via Graph, told the operator nothing about
      # whether replies will work.
      outgoing = test_outgoing
      return { :ok => false, :message => outgoing[:message], :folders => folders } unless outgoing[:ok]

      { :ok      => true,
        :message => I18n.t(:notice_helpdesk_connection_ok),
        :folders => folders,
        :sent_folder => sent_folder_for_report }
    rescue StandardError => e
      { :ok => false, :message => e.message, :folders => [] }
    end

    # Opens a single IMAP connection for the whole block; MailProcessor wraps a
    # complete fetch cycle in it so one connection serves every message.
    def with_session(&block)
      @imap.with_session { block.call(self) }
    end

    def close
      @imap.close
    end

    private

    def test_outgoing
      case @mailbox.outgoing_route
      when 'mailbox_smtp'
        @smtp.configured? ? @smtp.test_connection : { :ok => true, :message => nil }
      when 'graph'
        GraphProvider.new(@mailbox).test_connection
      else
        # Redmine's own relay - its health is Redmine's business, not ours.
        { :ok => true, :message => nil }
      end
    end

    # Naming the folder here makes a wrong guess visible before the first reply
    # rather than in a log line afterwards.
    def sent_folder_for_report
      @imap.with_session { @imap.sent_folder_name }
    rescue StandardError
      nil
    end

    def to_meta(data)
      uid = data.attr['UID']
      return nil if uid.nil?

      header = data.attr.find { |k, _v| k.to_s.start_with?('BODY[HEADER.FIELDS') }&.last
      parsed = parse_header(header)

      MailProvider::MessageMeta.new(
        :id                  => uid.to_s,
        :subject             => parsed ? parsed.subject.to_s : '',
        :from_address        => from_address(parsed),
        :from_name           => from_name(parsed),
        :received_at         => received_at(data, parsed),
        :internet_message_id => MailProvider.normalize_message_id(parsed && parsed.message_id)
      )
    end

    # The mail gem gives us RFC-2047 decoding of Subject and From for free.
    def parse_header(header)
      return nil if header.blank?

      Mail.read_from_string(header.to_s)
    rescue StandardError
      nil
    end

    def from_address(parsed)
      return '' unless parsed

      Array(parsed.from).first.to_s.downcase
    rescue StandardError
      ''
    end

    def from_name(parsed)
      return '' unless parsed

      field = parsed[:from]
      (field && field.respond_to?(:display_names) ? Array(field.display_names).first : nil).to_s
    rescue StandardError
      ''
    end

    # INTERNALDATE is what the server recorded; the Date header is the sender's
    # claim and only used as a fallback.
    def received_at(data, parsed)
      raw = data.attr['INTERNALDATE']
      return raw if raw.is_a?(Time)

      return Time.parse(raw.to_s) if raw.present?

      parsed && parsed.date ? parsed.date.to_time : nil
    rescue StandardError
      nil
    end
  end
end
