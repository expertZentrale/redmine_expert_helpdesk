# Archives the MIME of an agent reply (or initial mail) as an .eml attachment on
# the ticket, the outgoing counterpart of the "Original E-Mail" MailProcessor
# stores for every incoming mail. PreviousMessage reads it back when the next
# reply appends the conversation so far.
#
# The copy is bookkeeping: a failure is logged and swallowed, because the
# customer already has the mail by the time it is stored and an error would
# invite the agent to send it a second time.
module RedmineExpertHelpdesk
  module SentMailArchive
    DESCRIPTION          = 'Sent E-Mail'.freeze
    ORIGINAL_DESCRIPTION = 'Original E-Mail'.freeze

    module_function

    # Stores +mime+ on the message's issue and links it as the message's
    # eml_attachment. Returns the Attachment, or nil.
    def attach!(message, mime, author)
      return nil if message.nil? || mime.blank?

      filename = "sent_mail_#{Time.current.strftime('%Y%m%d_%H%M%S')}.eml"
      io = StringIO.new(strip_bcc(mime).dup.force_encoding('BINARY'))
      io.define_singleton_method(:original_filename) { filename }
      io.define_singleton_method(:content_type)      { 'message/rfc822' }

      attachment = Attachment.new(
        :container   => message.issue,
        :file        => io,
        :description => DESCRIPTION,
        :author      => author || User.anonymous
      )
      attachment.save!
      message.update_column(:eml_attachment_id, attachment.id)
      attachment
    rescue StandardError => e
      Rails.logger.warn "Helpdesk: sent mail of ##{message&.issue_id} not archived: #{e.class}: #{e.message}"
      nil
    end

    # The .eml files the plugin attaches itself - incoming originals and sent
    # copies. Neither is evidence the customer supplied.
    def archived_eml?(attachment)
      [DESCRIPTION, ORIGINAL_DESCRIPTION].include?(attachment&.description)
    end

    # Removes the Bcc header (and its folded continuation lines) from the
    # header block. Everyone who can open the ticket can download the copy, and
    # a blind recipient must stay blind there too.
    def strip_bcc(mime)
      raw = mime.to_s.dup.force_encoding('BINARY')
      # The header block ends with its own line break; the empty line after it
      # starts the rest.
      match = raw.match(/\r?\n(\r?\n)/n)
      head  = match ? raw[0...match.begin(1)] : raw
      rest  = match ? raw[match.begin(1)..] : ''.b

      lines   = head.split(/(?<=\n)/n)
      kept    = []
      in_bcc  = false
      lines.each do |line|
        if line.match?(/\A[ \t]/n)
          kept << line unless in_bcc
          next
        end
        in_bcc = line.match?(/\Abcc[ \t]*:/in)
        kept << line unless in_bcc
      end
      kept.join + rest
    end
  end
end
