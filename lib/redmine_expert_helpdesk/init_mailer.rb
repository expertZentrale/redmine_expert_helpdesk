# Verknuepft einen Kundenkontakt mit einem Ticket und sendet optional eine initiale Mail.
# Wird beim manuellen Zuordnen an bestehende Tickets und beim Erstellen neuer Tickets verwendet.
module RedmineExpertHelpdesk
  class InitMailer
    def self.call(**kwargs)
      new(**kwargs).call
    end

    def initialize(issue:, contact_email:, mailbox:, user:,
                   contact_name: nil, send_mail: true, mail_body: nil,
                   cc: nil, bcc: nil)
      @issue         = issue
      # contact_email darf eine kommagetrennte Liste sein; der erste Empfaenger
      # wird als Kundenkontakt verknuepft, alle erhalten die Mail.
      @to_list       = split_addresses(contact_email)
      @contact_email = @to_list.first.to_s
      @cc_list       = split_addresses(cc)
      @bcc_list      = split_addresses(bcc)
      @contact_name  = contact_name.to_s.strip.presence
      @mailbox       = mailbox
      @user          = user
      @send_mail     = send_mail
      @mail_body     = mail_body.to_s.strip
    end

    def call
      contact = HelpdeskContact.find_or_create_for(@contact_email, @contact_name, @issue.project)
      HelpdeskTicketInfo.link!(@issue, contact, @mailbox)

      if @send_mail && @mailbox
        message_id = generate_message_id(@mailbox.mailbox_address)
        subject    = rendered_subject(contact)
        body_html  = rendered_body(contact)

        sent_filenames =
          if @mailbox.outgoing_route == 'smtp'
            send_smtp(subject, body_html, message_id)
          else
            send_provider_mime(subject, body_html, message_id)
          end

        HelpdeskMessage.create!(
          :issue            => @issue,
          :helpdesk_contact => contact,
          :helpdesk_mailbox => @mailbox,
          :direction        => 'out',
          :message_id       => message_id,
          :subject          => subject,
          :sent_at          => Time.current,
          :recipient_to     => @to_list.join(', '),
          :recipient_cc     => @cc_list.join(', ').presence,
          :recipient_bcc    => @bcc_list.join(', ').presence,
          :sent_attachments => Array(sent_filenames).uniq.join(', ').presence
        )
      else
        HelpdeskMessage.create!(
          :issue            => @issue,
          :helpdesk_contact => contact,
          :helpdesk_mailbox => @mailbox,
          :direction        => 'init',
          :sent_at          => Time.current
        )
      end

      contact
    end

    private

    # Kommagetrennte Adressliste in normalisierte Einzeladressen zerlegen
    def split_addresses(value)
      value.to_s.split(/[,;]/).map { |a| a.strip.downcase }.reject(&:blank?).uniq
    end

    def rendered_subject(contact)
      project_setting = HelpdeskProjectSetting.for_project(@issue.project)
      ctx = { :issue => @issue, :contact => contact, :user => @user }
      TemplateRenderer.render(project_setting.effective_subject_template, ctx)
    end

    def rendered_body(contact)
      ctx         = { :issue => @issue, :contact => contact, :user => @user }
      body_source = @mail_body.presence || @issue.description.to_s

      # Wiki-Markup in HTML umwandeln (Beschreibungsfeld enthaelt Redmine-Formatierung)
      body_html = description_to_html(body_source)

      header_html = plain_to_html(TemplateRenderer.render(@mailbox.reply_header.to_s, ctx))
      footer_html = plain_to_html(TemplateRenderer.render(@mailbox.effective_footer_template, ctx))
      [header_html, body_html, footer_html].reject(&:blank?).join("\n")
    end

    # Konvertiert Redmine-Wiki-Markup in HTML.
    def description_to_html(text)
      return '' if text.blank?
      return text if text.match?(/<\w/)  # schon HTML (z. B. manueller Mailtext)
      begin
        Redmine::WikiFormatting.formatter.new(text).to_html.to_s
      rescue StandardError
        plain_to_html(text)
      end
    end

    # Findet Issue-Anhaenge, die per <img src="filename"> im HTML referenziert werden.
    def find_inline_attachments(html)
      return [] if html.blank?
      srcs = html.scan(/src=["']([^"']+)["']/i).flatten
      return [] if srcs.empty?
      att_map = @issue.attachments.index_by(&:filename)
      srcs.filter_map { |src| att_map[File.basename(src)] }.uniq
    end

    def plain_to_html(text)
      return '' if text.blank?
      return text if text.include?('<') && text.include?('>')
      '<p>' + ERB::Util.html_escape(text).gsub(/\n{2,}/, '</p><p>').gsub("\n", '<br>') + '</p>'
    end

    def generate_message_id(from_address)
      domain = from_address.to_s.split('@').last.presence || 'helpdesk.local'
      "<#{SecureRandom.uuid}@#{domain}>"
    end

    # Issue-Anhaenge, die NICHT als Inline-Bild im HTML referenziert sind, werden
    # als regulaere Datei-Anhaenge mitgeschickt (z. B. hochgeladene PDFs/Dokumente).
    def regular_attachments(inline_atts)
      inline_ids = inline_atts.map(&:id)
      @issue.attachments.to_a
            .reject { |a| inline_ids.include?(a.id) }
            .select { |a| a.diskfile && File.exist?(a.diskfile) }
    end

    # SMTP: Inline-Bilder als Base64-Data-URI einbetten, uebrige Anhaenge anhaengen.
    def send_smtp(subject, body_html, message_id)
      inline_atts  = find_inline_attachments(body_html)
      regular_atts = regular_attachments(inline_atts)
      processed    = embed_inline_images(body_html, inline_atts)

      mail_obj             = Mail.new
      mail_obj.message_id  = message_id
      mail_obj.from        = @mailbox.from_address
      # Opt-in only; see HelpdeskMailbox#reply_to_address.
      reply_to_addr        = @mailbox.reply_to_address
      mail_obj.reply_to    = reply_to_addr if reply_to_addr
      mail_obj.to          = @to_list
      mail_obj.cc          = @cc_list  if @cc_list.any?
      mail_obj.bcc         = @bcc_list if @bcc_list.any?
      mail_obj.subject     = subject

      if regular_atts.any?
        mail_obj.html_part do
          content_type 'text/html; charset=UTF-8'
          body processed
        end
        regular_atts.each do |att|
          mail_obj.add_file(:filename => att.filename, :content => File.binread(att.diskfile))
        end
      else
        mail_obj.content_type = 'text/html; charset=UTF-8'
        mail_obj.body         = processed
      end

      mail_obj.delivery_method(ActionMailer::Base.delivery_method,
                               ActionMailer::Base.smtp_settings || {})
      MailLogger.track(
        :kind => 'initial', :mailbox => @mailbox, :issue => @issue,
        :to => @to_list, :cc => @cc_list, :bcc => @bcc_list,
        :subject => subject, :message_id => message_id,
        :detail => "delivery_method=#{ActionMailer::Base.delivery_method}"
      ) { mail_obj.deliver! }
      # Redmine's relay files nothing in the mailbox itself. No-op for Graph.
      MailProvider.for(@mailbox).archive_sent(mail_obj.to_s)

      # Versendete Dateien (regulaere Anhaenge + inline eingebettete Bilder) fuer die
      # Anzeige im Kundenbereich zurueckgeben.
      regular_atts.map(&:filename) + inline_atts.map(&:filename)
    end

    # Roher MIME-Versand ueber das Backend des Postfachs (Graph-API oder eigener
    # SMTP-Server): CID-Inline-Bilder + regulaere Anhaenge in einer vollstaendigen
    # MIME-Nachricht.
    def send_provider_mime(subject, body_html, message_id)
      inline_atts            = find_inline_attachments(body_html)
      regular_atts           = regular_attachments(inline_atts)
      cid_map, html_with_cid = build_cid_map(body_html, inline_atts)
      mime_msg = build_cid_mime(@mailbox.mailbox_address, @to_list.join(', '),
                                subject, html_with_cid, regular_atts, cid_map, message_id)
      MailLogger.track(
        :kind => 'initial', :mailbox => @mailbox, :issue => @issue,
        :to => @to_list, :cc => @cc_list, :bcc => @bcc_list,
        :subject => subject, :message_id => message_id
      ) { MailProvider.outgoing_for(@mailbox).send_mail_mime(mime_msg) }

      # Versendete Dateien (regulaere Anhaenge + inline eingebettete Bilder) fuer die
      # Anzeige im Kundenbereich zurueckgeben.
      regular_atts.map(&:filename) + cid_map.keys.map(&:filename)
    end

    # Ersetzt src="filename" durch data:-URI fuer SMTP-Transport.
    def embed_inline_images(html, atts)
      processed = html.dup
      atts.each do |att|
        next unless att.diskfile && File.exist?(att.diskfile)
        mime     = att.content_type.presence ||
                   Redmine::MimeType.of(att.filename) || 'application/octet-stream'
        data_uri = "data:#{mime};base64,#{Base64.strict_encode64(File.binread(att.diskfile))}"
        safe_fn  = Regexp.escape(att.filename)
        processed = processed.gsub(/(src=)(["'])([^"']*#{safe_fn}[^"']*)\2/i) do
          "#{$1}#{$2}#{data_uri}#{$2}"
        end
      end
      processed
    end

    # Ersetzt src="filename" durch cid:... und gibt [{att => cid}, html] zurueck.
    def build_cid_map(html, atts)
      cid_map   = {}
      processed = html.dup
      atts.each_with_index do |att, i|
        cid      = "img#{att.id}x#{i}@helpdesk.local"
        safe_fn  = Regexp.escape(att.filename)
        replaced = processed.gsub(/(src=)(["'])([^"']*#{safe_fn}[^"']*)\2/i) do
          "#{$1}#{$2}cid:#{cid}#{$2}"
        end
        next if replaced == processed
        cid_map[att] = cid
        processed    = replaced
      end
      [cid_map, processed]
    end

    # Erstellt eine vollstaendige RFC-2822-MIME-Nachricht mit optionalen CID-Inline-Bildern
    # und regulaeren Datei-Anhaengen (multipart/mixed umschliesst multipart/related).
    def build_cid_mime(from, to, subject, body_html, regular_atts, cid_map, message_id)
      bnd_mixed   = "mix#{SecureRandom.hex(10)}"
      bnd_related = "rel#{SecureRandom.hex(10)}"
      has_inline  = cid_map.any?
      has_regular = Array(regular_atts).any? { |a| a.diskfile && File.exist?(a.diskfile) }

      ln = []
      ln << "MIME-Version: 1.0"
      ln << "Message-ID: #{message_id}" if message_id.present?
      ln << "From: #{from}"
      ln << "To: #{to}"
      ln << "Cc: #{@cc_list.join(', ')}" if @cc_list.any?
      # Bcc-Header: Exchange entfernt ihn beim Versand und stellt an die Adressen zu
      ln << "Bcc: #{@bcc_list.join(', ')}" if @bcc_list.any?
      ln << "Subject: #{mime_encode_subject(subject)}"

      if !has_inline && !has_regular
        ln << "Content-Type: text/html; charset=\"UTF-8\""
        ln << "Content-Transfer-Encoding: base64"
        ln << ""
        ln << mime_base64(body_html)
        return ln.join("\r\n")
      end

      if has_inline && has_regular
        ln << "Content-Type: multipart/mixed; boundary=\"#{bnd_mixed}\""
        ln << ""
        ln << "--#{bnd_mixed}"
        ln << "Content-Type: multipart/related; type=\"text/html\"; boundary=\"#{bnd_related}\""
        ln << ""
        ln << "--#{bnd_related}"
      elsif has_inline
        ln << "Content-Type: multipart/related; type=\"text/html\"; boundary=\"#{bnd_related}\""
        ln << ""
        ln << "--#{bnd_related}"
      else
        ln << "Content-Type: multipart/mixed; boundary=\"#{bnd_mixed}\""
        ln << ""
        ln << "--#{bnd_mixed}"
      end

      # HTML-Teil
      ln << "Content-Type: text/html; charset=\"UTF-8\""
      ln << "Content-Transfer-Encoding: base64"
      ln << ""
      ln << mime_base64(body_html)

      if has_inline
        cid_map.each do |att, cid|
          next unless att.diskfile && File.exist?(att.diskfile)
          mt = att.content_type.presence ||
               Redmine::MimeType.of(att.filename) || 'application/octet-stream'
          ln << ""
          ln << "--#{bnd_related}"
          ln << "Content-Type: #{mt}"
          ln << "Content-Transfer-Encoding: base64"
          ln << "Content-ID: <#{cid}>"
          ln << "Content-Disposition: inline; filename=\"#{att.filename}\""
          ln << ""
          ln << mime_base64(File.binread(att.diskfile))
        end
        ln << ""
        ln << "--#{bnd_related}--"
      end

      if has_regular
        regular_atts.each do |att|
          next unless att.diskfile && File.exist?(att.diskfile)
          mt = att.content_type.presence || 'application/octet-stream'
          ln << ""
          ln << "--#{bnd_mixed}"
          ln << "Content-Type: #{mt}; name=\"#{att.filename}\""
          ln << "Content-Transfer-Encoding: base64"
          ln << "Content-Disposition: attachment; filename=\"#{att.filename}\""
          ln << ""
          ln << mime_base64(File.binread(att.diskfile))
        end
        ln << ""
        ln << "--#{bnd_mixed}--"
      end

      ln.join("\r\n")
    end

    def mime_encode_subject(subject)
      subject.ascii_only? ? subject :
        "=?UTF-8?B?#{Base64.strict_encode64(subject.encode('UTF-8'))}?="
    end

    def mime_base64(data)
      raw = data.dup.force_encoding('BINARY')
      Base64.encode64(raw).gsub(/\r?\n/, "\r\n").chomp
    end
  end
end

