# Verknuepft einen Kundenkontakt mit einem Ticket und sendet optional eine initiale Mail.
# Wird beim manuellen Zuordnen an bestehende Tickets und beim Erstellen neuer Tickets verwendet.
#
# Experimental hand-over (see Handover): with the mail switched on, the helpdesk
# address of a participating project is taken out of To/Cc/Bcc and the ticket is
# created there directly. It carries what the mail would have carried - the
# mail text and every attachment of the ticket - so unlike a reply there is
# nothing to choose. The first remaining To address is the customer.
module RedmineExpertHelpdesk
  class InitMailer
    EMAIL_RE = /\A[^@\s]+@[^@\s]+\z/.freeze

    # The message is shown to the agent as it is.
    class Error < StandardError; end

    # What happened, for the caller's message. contact is nil when only
    # hand-overs were left in To; handovers are [ticket, mailbox] pairs.
    Result = Struct.new(:contact, :mailed, :handovers)

    def self.call(**kwargs)
      new(**kwargs).call
    end

    # "Project B: #123, Project C: #124" for the agent's messages.
    def self.handover_list(handovers)
      handovers.map { |issue, mailbox| "#{mailbox.project.name}: ##{issue.id}" }.join(', ')
    end

    # move_cc: the agent ticked "move the first Cc recipient to To" - the form
    # offers it when To is empty after the hand-over addresses left it.
    def initialize(issue:, contact_email:, mailbox:, user:,
                   contact_name: nil, send_mail: true, mail_body: nil,
                   cc: nil, bcc: nil, move_cc: false)
      @issue         = issue
      # contact_email darf eine kommagetrennte Liste sein; der erste Empfaenger
      # wird als Kundenkontakt verknuepft, alle erhalten die Mail.
      @to_list       = split_addresses(contact_email)
      @cc_list       = split_addresses(cc)
      @bcc_list      = split_addresses(bcc)
      @contact_name  = contact_name.to_s.strip.presence
      @mailbox       = mailbox
      @user          = user
      @send_mail     = send_mail
      @mail_body     = mail_body.to_s.strip
      @move_cc       = move_cc
      @handovers     = []
      @bcc_only      = []
    end

    def call
      if @send_mail && @mailbox
        take_out_handovers
        @to_list << @cc_list.shift if @move_cc && @to_list.empty? && @cc_list.any?
      end
      check_recipients!

      contact = link_contact if @to_list.any?
      created = hand_over(contact)
      mailed  = false
      begin
        if @send_mail && @mailbox && @to_list.any?
          send_and_record(contact)
          mailed = true
        elsif !@send_mail
          HelpdeskMessage.create!(
            :issue            => @issue,
            :helpdesk_contact => contact,
            :helpdesk_mailbox => @mailbox,
            :direction        => 'init',
            :sent_at          => Time.current
          )
        end
      rescue StandardError => e
        # The hand-over is not taken back: this ticket exists either way, and
        # nobody is asked to send it again.
        Rails.logger.error "Helpdesk initial mail for ##{@issue.id} failed: #{e.class}: #{e.message}"
        raise Error, failure_message(e, created)
      ensure
        finish_handovers(created)
      end

      Result.new(contact, mailed, created)
    end

    private

    # One recipient field, split like the reply form's (HelpdeskMessage.scan_tokens):
    # a comma inside quotes or angle brackets separates nothing, so
    # "Doe, Jane" <jane@doe.com> stays one recipient. Unique by address.
    def split_addresses(value)
      HelpdeskMessage.scan_tokens(value).map(&:strip).reject(&:blank?)
                     .uniq { |token| HelpdeskMessage.bare_address(token).downcase }
    end

    def take_out_handovers
      targets = Handover.targets_for(@issue.project, @user)
      return if targets.empty?

      hits = {}
      @to_list, @cc_list, @bcc_list = [@to_list, @cc_list, @bcc_list].map.with_index do |list, field|
        list.reject do |address|
          mailbox = targets[HelpdeskMessage.bare_address(address).downcase]
          (hits[field] ||= []) << mailbox if mailbox
          mailbox
        end
      end
      open = Array(hits[0]) + Array(hits[1])
      @handovers = (open + Array(hits[2])).uniq(&:project_id)
      @bcc_only  = Array(hits[2]).map(&:project_id) - open.map(&:project_id)
    end

    # Nothing is done when the mail cannot go out as asked: a mail without a To
    # recipient has no customer, and quietly sending it to Cc alone would not
    # be what the agent saw in the form.
    def check_recipients!
      # A hand-over copies the ticket into another project; the callers check
      # this as well (HelpdeskInitController#find_issue, the author of a new
      # ticket).
      raise Error, I18n.t(:notice_not_authorized) if @handovers.any? && !@issue.visible?(@user)

      if @to_list.empty?
        if @send_mail && @handovers.any? && @cc_list.empty? && @bcc_list.empty?
          return # hand-over only, no mail
        end
        raise Error, I18n.t(:error_helpdesk_init_no_to) if @send_mail && (@cc_list.any? || @bcc_list.any?)
        raise Error, I18n.t(@send_mail ? :error_helpdesk_init_no_recipient : :error_helpdesk_invalid_email)
      end
      raise Error, I18n.t(:error_helpdesk_invalid_email) unless customer_address.match?(EMAIL_RE)
    end

    # The first To recipient, without a display name.
    def customer_address
      HelpdeskMessage.bare_address(@to_list.first).downcase
    end

    def link_contact
      contact = HelpdeskContact.find_or_create_for(customer_address, @contact_name, @issue.project)
      HelpdeskTicketInfo.link!(@issue, contact, @mailbox)
      contact
    end

    # All or nothing: a hand-over that fails takes the ones before it back, so
    # the agent can simply try again.
    def hand_over(contact)
      created = []
      @handovers.each do |mailbox|
        issue = Handover.new(:source => @issue, :mailbox => mailbox, :user => @user, :mode => 'note',
                             :note => @mail_body.presence || @issue.description.to_s,
                             :attachments => @issue.attachments.reload.to_a, :contact => contact,
                             :bcc => @bcc_only.include?(mailbox.project_id)).call
        created << [issue, mailbox]
      end
      created
    rescue StandardError => e
      # Handover.undo keeps one the other team has worked on already; that one
      # is final then, and the message names it.
      kept = created.reject do |issue, _|
        Handover.undo(issue)
      rescue StandardError => undo_error
        Rails.logger.error "Helpdesk handover: ##{issue.id} could not be removed: #{undo_error.message}"
        false
      end
      kept.each { |issue, mailbox| Handover.finalize(issue, mailbox) }
      Rails.logger.error "Helpdesk handover (initial mail) failed: #{e.class}: #{e.message}"
      raise Error, I18n.t(:error_helpdesk_init_handover_failed, :message => e.message) if kept.empty?

      raise Error, "#{I18n.t(:error_helpdesk_init_handover_failed_kept, :message => e.message)} " \
                   "#{I18n.t(:text_helpdesk_handover_kept_after_failure, :targets => self.class.handover_list(kept))}"
    end

    # The source ticket records where the topic went, as a reply's note does.
    # A target reached by Bcc only makes the note private: its readers would
    # learn about a recipient the mail kept blind. The note is a record, not
    # news - no notification. The targets get theirs (Handover.finalize).
    def finish_handovers(created)
      return if created.empty?

      # First, and on its own: the hand-overs are committed either way, and a
      # note that fails must not cost them their notification. finalize never
      # raises.
      created.each { |issue, mailbox| Handover.finalize(issue, mailbox) }
      record_handover_note(created)
    end

    def record_handover_note(created)
      lines = created.map do |issue, mailbox|
        I18n.t(:text_helpdesk_handover_note_line, :issue => "##{issue.id}",
                                                  :target => "#{mailbox.project.name} (#{mailbox.mailbox_address})")
      end
      private_note = created.any? { |_, mailbox| @bcc_only.include?(mailbox.project_id) }
      journal = Journal.new(:journalized => @issue, :user => @user, :notes => lines.join("\n"),
                            :private_notes => private_note)
      journal.notify = false
      journal.save!
    rescue StandardError => e
      Rails.logger.error "Helpdesk handover (initial mail): recording on ##{@issue.id} failed: #{e.message}"
    end

    # Says what did happen: once delivered, sending again would mail twice.
    def failure_message(error, created)
      message = if @delivered
                  I18n.t(:warning_helpdesk_reply_not_recorded)
                else
                  I18n.t(:error_helpdesk_init_mail_failed, :message => error.message)
                end
      return message if created.empty?

      "#{message} #{I18n.t(:text_helpdesk_init_handover_kept, :targets => self.class.handover_list(created))}"
    end

    def send_and_record(contact)
      message_id = generate_message_id(@mailbox.mailbox_address)
      subject    = rendered_subject(contact)
      body_html  = rendered_body(contact)

      sent_filenames =
        if @mailbox.outgoing_route == 'smtp'
          send_smtp(subject, body_html, message_id)
        else
          send_provider_mime(subject, body_html, message_id)
        end
      @delivered = true

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

