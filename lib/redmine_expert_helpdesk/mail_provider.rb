# Provider-neutral mail backend interface.
#
# MailProcessor talks to a provider, never to a concrete client, so the same
# ingestion pipeline works for Microsoft 365 (Graph API) and generic IMAP/SMTP.
# Redmine's own MailHandler does the ticket creation, so a provider only has to
# supply raw RFC-2822 bytes plus list / move / mark-read / send.
#
# Instance interface (all mailbox-scoped - the address is bound at construction):
#
#   configured?                  -> true/false, no network
#   list_messages(limit)         -> Array<MessageMeta>, oldest first
#   message_mime(id)             -> String (BINARY), raw RFC-2822
#   mark_as_read(id)             -> nil, idempotent
#   move_message(id, folder)     -> nil, folder auto-created if missing
#   list_folders                 -> Array<String>, '/'-delimited display paths
#   create_folder(name)          -> String
#   find_or_create_folder(name)  -> String (Graph: folder id, IMAP: encoded name)
#   send_mail_mime(mime)         -> nil
#   archive_sent(mime)           -> nil   (file a copy in the Sent folder)
#   test_connection              -> {:ok, :message, :folders}, never raises
#   with_session { |p| ... }     -> block value; opens one connection for IMAP
#   close                        -> nil
module RedmineExpertHelpdesk
  module MailProvider
    # Normalized message metadata. Providers translate their native payload into
    # this, so MailProcessor never sees Graph JSON or IMAP FETCH attributes.
    MessageMeta = Struct.new(
      :id,                  # String, opaque handle (Graph message id / IMAP UID)
      :subject,             # String, decoded; may be ''
      :from_address,        # String, lowercased; may be ''
      :from_name,           # String; may be ''
      :received_at,         # Time or nil
      :internet_message_id, # String WITHOUT angle brackets; may be ''
      :keyword_init => true
    )

    class ProviderError < StandardError
      attr_reader :status, :body

      def initialize(message, status = nil, body = nil)
        super(message)
        @status = status
        @body = body
      end
    end

    # Credentials missing or incomplete - no point retrying.
    class ConfigurationError < ProviderError; end

    # Server rejected the credentials or token.
    class AuthenticationError < ProviderError; end

    class << self
      def for(mailbox)
        case mailbox.provider
        when 'imap' then ImapProvider.new(mailbox)
        else             GraphProvider.new(mailbox)
        end
      end

      # The receiving backend is not automatically the sender: a mailbox can send
      # through its own server, through the central Graph registration, or (route
      # 'smtp') through no provider at all. Anything that sends must ask for this
      # one rather than #for - three call sites each grew their own copy of this
      # branch, and each of them was wrong at least once.
      def outgoing_for(mailbox)
        case mailbox.outgoing_route
        when 'mailbox_smtp' then self.for(mailbox)
        else                     GraphProvider.new(mailbox)
        end
      end

      # Strips angle brackets from a Message-ID header value.
      def normalize_message_id(value)
        value.to_s.strip.delete('<>')
      end
    end
  end
end
