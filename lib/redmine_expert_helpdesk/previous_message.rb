# The previous message of a conversation, appended below an agent's reply the
# way a mail client does it on "Reply": a header block (From, Sent, To, Cc,
# Subject) and the original HTML body - not "> "-quoted text.
#
# Only the latest message is appended. It already carries the older history
# below itself, exactly as it does in a mail client.
#
# Sources, best first:
#   1. the archived .eml of the message (incoming mail: "Original E-Mail";
#      our own replies: "Sent E-Mail", see SentMailArchive),
#   2. for rows without one (replies sent before the copy was archived, legacy
#      imports), the journal note linked to the row - or, for the mail that
#      opened the ticket, the issue description - rendered with the wiki
#      formatter and a header built from the row's columns.
# Nothing usable means nothing is appended.
#
# Images: the reply's own embedding pass (ReplyImages, run on the whole mail
# body) only knows the ticket's attachments. Every <img> of the appended part is
# therefore pointed at the attachment MailHandler stored for it (by Content-ID,
# via InlineImages) or removed - never sent as a reference the customer's mail
# client cannot resolve.
require 'loofah'

module RedmineExpertHelpdesk
  class PreviousMessage
    include Redmine::I18n

    HEADER_FIELDS = %i[from sent to cc subject].freeze

    # The latest message of the conversation, or nil.
    #
    # Incoming mails always count. Outgoing rows count only when they carry a
    # Message-ID: the reply form and the initial mail store it, the automated
    # mails (autoresponder, completeness follow-up) do not - and those are not
    # what the customer would expect to see quoted under an agent's answer.
    # Direction "init" is a ticket opened without any mail.
    def self.latest(issue)
      scope = HelpdeskMessage.where(:issue_id => issue.id)
      table = HelpdeskMessage.table_name
      scope.where(:direction => 'in')
           .or(scope.where(:direction => 'out').where.not(:message_id => [nil, '']))
           .order(Arel.sql("COALESCE(#{table}.sent_at, #{table}.created_at) DESC"))
           .order(:id => :desc)
           .first
    end

    # HTML to append below the reply, or nil. Never raises: a reply must not
    # fail because an old mail could not be read.
    def self.html_for(issue)
      message = latest(issue)
      message && new(issue, message).to_html
    rescue StandardError => e
      Rails.logger.warn "Helpdesk: previous message of ##{issue&.id} not appended: #{e.class}: #{e.message}"
      nil
    end

    def initialize(issue, message)
      @issue   = issue
      @message = message
    end

    def to_html
      header, body = from_eml || from_journal
      return nil if body.blank?

      wrap(header, body)
    end

    private

    # --- archived .eml -------------------------------------------------------

    def from_eml
      mail = read_eml
      return nil unless mail

      # The MIME we hand to Graph has no Date header (Exchange adds one on
      # sending), so our own archived replies take the row's time.
      sent = mail.date&.to_time || @message.sent_at || @message.created_at
      header = {
        :from    => field(mail, :from),
        :sent    => sent && format_sent(sent),
        :to      => field(mail, :to),
        :cc      => field(mail, :cc),
        :subject => utf8(mail.subject)
      }
      body = eml_body(mail)
      body.blank? ? nil : [header, body]
    end

    def read_eml
      eml  = @message.eml_attachment
      path = eml&.diskfile
      return nil if path.blank? || !File.exist?(path)

      Mail.read_from_string(File.binread(path))
    rescue StandardError => e
      Rails.logger.warn "Helpdesk: .eml of message ##{@message.id} not readable: #{e.message}"
      nil
    end

    # The HTML part when there is one, the text part otherwise.
    def eml_body(mail)
      html_part = mail.multipart? ? mail.html_part : (mail.mime_type == 'text/html' ? mail : nil)
      if html_part
        html = InlineImages.decoded_body(html_part)
        return sanitize(inner_body(html), cid_resolver(mail)) if html.present?
      end

      text_part = mail.multipart? ? mail.text_part : (mail.mime_type.to_s.in?(['', 'text/plain']) ? mail : nil)
      text = text_part && InlineImages.decoded_body(text_part)
      text.present? ? text_to_html(text) : nil
    end

    # Only what is inside <body>: <head> carries styles and meta tags meant for
    # a whole document, not for a block inside another mail.
    def inner_body(html)
      html[%r{<body\b[^>]*>(.*)</body\s*>}im, 1] ||
        html.sub(%r{<head\b.*?</head\s*>}im, '')
    end

    # Maps the mail's cid: references onto the ticket attachments MailHandler
    # stored for them - matched by content, as InlineImages does on ingest.
    def cid_resolver(mail)
      index = nil
      lambda do |src|
        next generic_src(src) unless src.to_s.strip =~ /\Acid:(.+)\z/im

        index ||= InlineImages.cid_index(mail, InlineImages.newest_first(@issue.attachments.to_a))
        attachment = index[InlineImages.index_key(Regexp.last_match(1))]
        attachment && InlineImages.target(attachment)
      end
    end

    # --- journal fallback -------------------------------------------------------

    def from_journal
      text = fallback_text
      return nil if text.blank?

      html = begin
        Redmine::WikiFormatting.formatter.new(text).to_html.to_s
      rescue StandardError
        text_to_html(text)
      end
      [fallback_header, sanitize(html, name_resolver)]
    end

    def fallback_text
      if @message.journal_id
        journal = Journal.find_by(:id => @message.journal_id, :journalized_type => 'Issue',
                                  :journalized_id => @issue.id)
        journal&.notes
      elsif @message.direction == 'in' && first_incoming?
        # The mail that opened the ticket is its description.
        @issue.description
      end
    end

    def first_incoming?
      HelpdeskMessage.incoming.where(:issue_id => @issue.id).order(:id).pick(:id) == @message.id
    end

    def fallback_header
      {
        :from    => fallback_from,
        :sent    => (time = @message.sent_at || @message.created_at) && format_sent(time),
        :to      => @message.recipient_to,
        :cc      => @message.recipient_cc,
        :subject => @message.subject
      }
    end

    def fallback_from
      if @message.direction == 'in'
        contact = @message.helpdesk_contact
        return nil unless contact

        contact.name.present? ? "#{contact.name} <#{contact.email}>" : contact.email
      else
        mailbox = @message.helpdesk_mailbox
        mailbox && (mailbox.from_address.presence || mailbox.mailbox_address)
      end
    end

    # The wiki formatter writes an inline image as <img src="name.png">, which
    # Redmine resolves against the ticket's attachments while rendering the
    # page; the mail gets the same attachment by its download path.
    def name_resolver
      lambda do |src|
        value = src.to_s.strip
        next generic_src(value) if value.match?(%r{\A(https?:|data:|cid:)|/attachments/download/}i)

        attachment = Attachment.latest_attach(@issue.attachments, CGI.unescape(value).split('/').last.to_s)
        attachment && InlineImages.target(attachment)
      end
    end

    # --- shared -------------------------------------------------------------------

    # Remote and embedded images stay, a download path stays when it names one
    # of this ticket's attachments, everything else (relative paths, file:,
    # cid: nobody resolved) has nothing to show in the customer's mail client.
    def generic_src(src)
      value = src.to_s.strip
      return value if value.match?(%r{\Ahttps?://}i) || value.match?(%r{\Adata:image/}i)

      id = value[%r{/attachments/download/(\d+)/}i, 1]
      return value if id && @issue.attachments.any? { |a| a.id == id.to_i }

      nil
    end

    def sanitize(html, image_resolver)
      fragment = Loofah.fragment(html.to_s)
      fragment.scrub!(Scrubber.new(image_resolver))
      fragment.to_s
    end

    def text_to_html(text)
      ERB::Util.html_escape(text.to_s.strip).gsub(/\r\n?|\n/, "<br>\n")
    end

    def wrap(header, body)
      lines = HEADER_FIELDS.filter_map do |key|
        value = header[key].to_s.strip
        next if value.empty?

        "<b>#{ERB::Util.html_escape(l(:"label_helpdesk_previous_message_#{key}"))}</b> " \
          "#{ERB::Util.html_escape(value)}"
      end

      <<~HTML
        <div class="hd-previous-message" style="margin-top:16px">
        <div style="border:none;border-top:solid #E1E1E1 1.0pt;padding:3.0pt 0cm 0cm 0cm">
        <p style="margin:0 0 12px 0">#{lines.join("<br>\n")}</p>
        </div>
        #{body}
        </div>
      HTML
    end

    # Address header as the reader would see it, display names decoded.
    def field(mail, name)
      value = mail[name]
      return nil if value.nil?

      utf8(value.decoded)
    rescue StandardError
      utf8(value&.value)
    end

    def utf8(value)
      return nil if value.nil?

      value.to_s.dup.force_encoding('UTF-8').scrub('')
    end

    # In the agent's time zone and language: the reply goes out in that
    # language too (header and footer templates are rendered the same way).
    def format_sent(time)
      zone = User.current.time_zone || Time.zone
      I18n.l(time.in_time_zone(zone), :format => l(:text_helpdesk_previous_message_date_format))
    rescue StandardError
      time.to_s
    end

    # Deny list, not allow list: a mail's formatting (tables, font, inline
    # styles, widths, colours) is what makes it recognisable and has to survive.
    # Removed is what could run code, load or submit something, or restyle the
    # reply around the appended part.
    class Scrubber < Loofah::Scrubber
      DROP_ELEMENTS = %w[script style iframe frame frameset object embed applet form input button
                         textarea select option meta link base title head noscript template svg math].freeze
      URL_ATTRIBUTES = %w[href src action formaction background lowsrc dynsrc poster cite longdesc
                          xlink:href].freeze
      UNSAFE_URL     = /\A(javascript|vbscript|livescript|data|mocha):/i
      UNSAFE_STYLE   = /expression\s*\(|javascript:|vbscript:|behavior\s*:|-moz-binding|@import/i

      def initialize(image_resolver)
        super()
        @direction      = :top_down
        @image_resolver = image_resolver
      end

      def scrub(node)
        if node.comment? || node.processing_instruction? || node.cdata?
          node.remove
          return STOP
        end
        return CONTINUE unless node.element?

        name = node.name.to_s.downcase
        if DROP_ELEMENTS.include?(name)
          node.remove
          return STOP
        end

        if name == 'img'
          src = @image_resolver.call(node['src'])
          if src.nil?
            node.remove
            return STOP
          end
          node['src'] = src
          node.remove_attribute('srcset')
        end

        clean_attributes(node, name)
        CONTINUE
      end

      private

      def clean_attributes(node, element)
        node.attribute_nodes.each do |attr|
          name = attr.name.to_s.downcase
          if name.start_with?('on') || name == 'srcdoc' || name == 'formaction'
            attr.remove
          elsif name == 'style'
            attr.remove if attr.value.to_s.match?(UNSAFE_STYLE)
          elsif URL_ATTRIBUTES.include?(name) && !(element == 'img' && name == 'src')
            attr.remove if attr.value.to_s.gsub(/[\s\x00-\x1f]/, '').match?(UNSAFE_URL)
          end
        end
      end
    end
  end
end
