# MailProvider adapter for Microsoft 365 mailboxes.
#
# Thin wrapper around the unchanged GraphClient: it binds the mailbox address
# (GraphClient takes it per call) and normalizes Graph JSON into MessageMeta.
module RedmineExpertHelpdesk
  class GraphProvider
    attr_reader :mailbox

    def initialize(mailbox, client = nil)
      @mailbox = mailbox
      @client = client || GraphClient.new
    end

    def configured?
      @client.configured?
    end

    def list_messages(limit = 25)
      raw = @client.list_messages(address, @mailbox.source_folder, limit) || []
      raw.map { |m| to_meta(m) }
    end

    def message_mime(id)
      @client.message_mime(address, id)
    end

    def mark_as_read(id)
      @client.mark_as_read(address, id)
      nil
    end

    def move_message(id, folder_name)
      @client.move_message(address, id, folder_name)
      nil
    end

    def list_folders
      @client.list_folders(address)
    end

    def create_folder(name)
      @client.create_folder(address, name)
      name
    end

    def find_or_create_folder(name)
      @client.find_or_create_folder(address, name)
    end

    def send_mail_mime(mime_string)
      @client.send_mail_mime(address, mime_string)
      nil
    end

    def test_connection
      unless configured?
        return { :ok => false, :message => l(:error_helpdesk_provider_not_configured), :folders => [] }
      end

      folders = list_folders
      { :ok => true, :message => l(:notice_helpdesk_connection_ok), :folders => folders }
    rescue StandardError => e
      { :ok => false, :message => e.message, :folders => [] }
    end

    # Graph is stateless HTTP - nothing to open or close.
    def with_session
      yield self
    end

    def close
      nil
    end

    private

    def address
      @mailbox.mailbox_address
    end

    def to_meta(raw)
      MailProvider::MessageMeta.new(
        :id                  => raw['id'].to_s,
        :subject             => raw['subject'].to_s,
        :from_address        => raw.dig('from', 'emailAddress', 'address').to_s.downcase,
        :from_name           => raw.dig('from', 'emailAddress', 'name').to_s,
        :received_at         => parse_time(raw['receivedDateTime']),
        :internet_message_id => MailProvider.normalize_message_id(raw['internetMessageId'])
      )
    end

    def parse_time(value)
      return nil if value.blank?

      Time.zone ? Time.zone.parse(value.to_s) : Time.parse(value.to_s)
    rescue ArgumentError
      nil
    end

    def l(*args)
      ::I18n.t(*args)
    end
  end
end
