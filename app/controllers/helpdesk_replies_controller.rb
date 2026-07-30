require 'base64'

# Antwort an den Kunden direkt aus dem Ticket heraus.
# Die Antwort wird mit Header-/Footer-Template des Postfachs versehen,
# via Graph sendMail aus dem Projektpostfach versendet und
# zusaetzlich als Kommentar (Journal) am Ticket dokumentiert.
class HelpdeskRepliesController < ApplicationController
  before_action :find_issue
  before_action :authorize_reply

  def create
    info    = HelpdeskTicketInfo.for_issue(@issue)
    mailbox = info&.helpdesk_mailbox&.enabled? ? info.helpdesk_mailbox : nil
    mailbox ||= @project.helpdesk_mailboxes.enabled.first

    contact = info&.helpdesk_contact

    if mailbox.nil? || contact.nil?
      render :json => { :success => false, :error => l(:error_helpdesk_no_recipient) },
             :status => :unprocessable_entity
      return
    end

    # Notizinhalt (Wiki-Markup) aus dem Redmine-Notizfeld
    note = params[:note_content].to_s
    if note.strip.blank?
      render :json => { :success => false, :error => l(:error_helpdesk_empty_reply) },
             :status => :unprocessable_entity
      return
    end

    reply_to  = params[:reply_to].to_s.strip.presence  || contact.email
    reply_cc  = params[:reply_cc].to_s.strip.gsub(/[\s,;]+\z/, '')
    reply_bcc = params[:reply_bcc].to_s.strip.gsub(/[\s,;]+\z/, '')

    # Betreff aus Projekteinstellungen mit Makro-Auswertung
    project_setting  = HelpdeskProjectSetting.for_project(@project)
    subject_template = project_setting.effective_subject_template
    context = { :issue => @issue, :contact => contact, :user => User.current }
    subject = RedmineExpertHelpdesk::TemplateRenderer.render(subject_template, context)

    # Wiki-Markup → HTML fuer den E-Mail-Body
    wiki_html = begin
      Redmine::WikiFormatting.formatter.new(note).to_html.to_s
    rescue StandardError
      "<p>#{ERB::Util.html_escape(note)}</p>"
    end

    header_html = plain_to_html(RedmineExpertHelpdesk::TemplateRenderer.render(mailbox.reply_header.to_s, context))
    footer_html = plain_to_html(RedmineExpertHelpdesk::TemplateRenderer.render(mailbox.effective_footer_template, context))
    body_html = [header_html, wiki_html, footer_html].reject(&:blank?).join("\n")

    # Anhaenge: nur IDs zulassen, die tatsaechlich zum Ticket gehoeren
    attachment_ids = Array(params[:attachment_ids]).map(&:to_i).reject(&:zero?)
    sent_filenames = []
    valid_att_ids  = attachment_ids.any? ? (attachment_ids & @issue.attachments.pluck(:id)) : []

    # Pending-Anhaenge (eingefuegte Bilder, noch nicht gespeichert) per Token
    inline_tokens = Array(params[:inline_attachment_tokens]).map(&:to_s).reject(&:blank?).first(20)
    inline_atts   = inline_tokens.filter_map { |tok| Attachment.find_by_token(tok) }
                                 .select { |a| a.author_id == User.current.id }

    message_id = nil

    if mailbox.effective_reply_transport == 'smtp'
      processed_html, embedded_atts = embed_inline_images(body_html, inline_atts)
      message_id = send_reply_smtp(mailbox, reply_to, reply_cc, reply_bcc, subject, processed_html,
                                   valid_att_ids, embedded_atts, sent_filenames)
    else
      # Roher MIME-Versand fuer zuverlaessige CID-Inline-Bilder – sowohl ueber
      # die Graph-API als auch ueber den eigenen SMTP-Server des Postfachs.
      # Der JSON-Ansatz funktioniert nicht, weil Exchange das HTML vor Zustellung
      # umschreibt und dabei cid:-Referenzen und isInline-Anhaenge entkoppelt.
      # Mit Content-Type: text/plain + base64-MIME bleibt die MIME-Struktur erhalten.
      message_id             = generate_message_id(mailbox.mailbox_address)
      regular_atts           = Attachment.where(:id => valid_att_ids).to_a
      cid_map, html_with_cid = build_cid_map(body_html, inline_atts)
      mime_msg = build_cid_mime(mailbox.mailbox_address, reply_to, reply_cc, reply_bcc,
                                subject, html_with_cid, cid_map, regular_atts, message_id)
      reply_provider(mailbox).send_mail_mime(mime_msg)
      sent_filenames.concat(regular_atts.map(&:filename))
      sent_filenames.concat(cid_map.keys.map(&:filename))
    end

    hd_msg = HelpdeskMessage.create!(
      :issue             => @issue,
      :helpdesk_contact  => contact,
      :helpdesk_mailbox  => mailbox,
      :direction         => 'out',
      :message_id        => message_id,
      :subject           => subject,
      :sent_at           => Time.current,
      :recipient_to      => reply_to,
      :recipient_cc      => reply_cc.presence,
      :recipient_bcc     => reply_bcc.presence,
      :sent_attachments  => sent_filenames.join(', ').presence
    )

    # ID zurueckgeben: das Formular schickt sie beim Issue-Update als Hidden-Field
    # mit, der controller_issues_edit_after_save-Hook verknuepft dann das Journal.
    # SLA: Kundenantwort stoppt die Reaktionsuhr.
    RedmineExpertHelpdesk::Sla.record_first_response!(@issue, Time.current)

    render :json => { :success => true, :helpdesk_message_id => hd_msg.id }
  rescue RedmineExpertHelpdesk::MailProvider::ProviderError => e
    render :json => { :success => false, :error => e.message }, :status => :unprocessable_entity
  rescue StandardError => e
    render :json => { :success => false, :error => e.message }, :status => :unprocessable_entity
  end

  private

  # 'mailbox_smtp' sends through the mailbox's own SMTP server, 'graph' through
  # the Graph API. Both take the same raw MIME, so the CID handling above is
  # shared.
  def reply_provider(mailbox)
    if mailbox.effective_reply_transport == 'mailbox_smtp'
      RedmineExpertHelpdesk::MailProvider.for(mailbox)
    else
      RedmineExpertHelpdesk::GraphProvider.new(mailbox)
    end
  end

  def build_recipients(addresses_str)
    addresses_str.to_s.split(/[,;]+/).map(&:strip).reject(&:blank?).map do |addr|
      { 'emailAddress' => { 'address' => addr } }
    end
  end

  # Wandelt einfachen Plaintext in minimal-HTML um (fuer Header-/Footer-Templates).
  def plain_to_html(text)
    return '' if text.blank?
    return text if text.include?('<') && text.include?('>')
    '<p>' + ERB::Util.html_escape(text).gsub(/\n{2,}/, '</p><p>').gsub("\n", '<br>') + '</p>'
  end

  # Sendet die Antwort via Redmines konfiguriertem SMTP-Transport.
  # Gibt die Message-ID der gesendeten Mail zurueck.
  def send_reply_smtp(mailbox, to, cc, bcc, subject, body_html, att_ids, embedded_atts, sent_filenames)
    mail_obj             = Mail.new
    mail_obj.message_id  = generate_message_id(mailbox.mailbox_address)
    mail_obj.from    = mailbox.mailbox_address
    mail_obj.to      = to
    mail_obj.cc      = cc  if cc.present?
    mail_obj.bcc     = bcc if bcc.present?
    mail_obj.subject = subject

    all_file_atts = Attachment.where(:id => att_ids).to_a + Array(embedded_atts)

    if all_file_atts.any?
      mail_obj.html_part do
        content_type 'text/html; charset=UTF-8'
        body body_html
      end
      all_file_atts.each do |att|
        sent_filenames << att.filename
        mail_obj.add_file(:filename => att.filename,
                          :content  => File.binread(att.diskfile))
      end
    else
      mail_obj.content_type = 'text/html; charset=UTF-8'
      mail_obj.body = body_html
    end

    delivery_method = ActionMailer::Base.delivery_method
    smtp_settings   = ActionMailer::Base.smtp_settings || {}
    mail_obj.delivery_method(delivery_method, smtp_settings)
    mail_obj.deliver!
    mail_obj.message_id
  end

  # Bettet eingefuegte Bilder als Base64-Data-URI direkt in den HTML-Body ein (fuer SMTP).
  # Gibt [processed_html, [embedded_attachment_objects]] zurueck.
  def embed_inline_images(body_html, inline_atts)
    return [body_html, []] if inline_atts.blank?

    processed = body_html.dup
    embedded  = []

    inline_atts.each do |att|
      next unless att.diskfile && File.exist?(att.diskfile)

      safe_fn  = Regexp.escape(att.filename)
      mime     = att.content_type.presence ||
                 Redmine::MimeType.of(att.filename) || 'application/octet-stream'
      data_uri = "data:#{mime};base64,#{Base64.strict_encode64(File.binread(att.diskfile))}"

      replaced = processed.gsub(/(src=)(["'])([^"']*#{safe_fn}[^"']*)\2/i) do
        "#{$1}#{$2}#{data_uri}#{$2}"
      end

      next if replaced == processed

      processed = replaced
      embedded << att
    end

    [processed, embedded]
  end

  # Baut eine CID-Map auf: ersetzt src="filename" im HTML durch cid:... und gibt
  # [{att => cid}, processed_html] zurueck.
  def build_cid_map(body_html, inline_atts)
    cid_map   = {}
    processed = body_html.dup
    inline_atts.each_with_index do |att, i|
      cid     = "img#{att.id}x#{i}@helpdesk.local"
      safe_fn = Regexp.escape(att.filename)
      replaced = processed.gsub(/(src=)(["'])([^"']*#{safe_fn}[^"']*)\2/i) do
        "#{$1}#{$2}cid:#{cid}#{$2}"
      end
      next if replaced == processed
      cid_map[att] = cid
      processed = replaced
    end
    [cid_map, processed]
  end

  # Erstellt eine vollstaendige RFC-2822-MIME-Nachricht mit CID-Inline-Bildern.
  # Die Nachricht wird anschliessend per Graph-API-MIME-Endpunkt versendet
  # (Content-Type: text/plain, Body: Base64 der MIME-Nachricht).
  def build_cid_mime(from, to, cc, bcc, subject, body_html, cid_map, regular_atts, message_id = nil)
    bnd_mixed   = "mix#{SecureRandom.hex(10)}"
    bnd_related = "rel#{SecureRandom.hex(10)}"
    has_inline  = cid_map.any?
    has_regular = regular_atts.reject { |a| !a.diskfile || !File.exist?(a.diskfile) }.any?

    ln = []
    ln << "MIME-Version: 1.0"
    ln << "Message-ID: #{message_id}" if message_id.present?
    ln << "From: #{from}"
    ln << "To: #{to}"
    ln << "Cc: #{cc}"   if cc.present?
    ln << "Bcc: #{bcc}" if bcc.present?
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

  # Base64-kodiert einen String fuer MIME (Zeilenumbruch alle 76 Zeichen, CRLF).
  def mime_base64(data)
    raw = data.dup.force_encoding('BINARY')
    Base64.encode64(raw).gsub(/\r?\n/, "\r\n").chomp
  end

  # RFC-2047-kodiert den E-Mail-Betreff wenn er Nicht-ASCII-Zeichen enthaelt.
  def mime_encode_subject(str)
    str.ascii_only? ? str : "=?UTF-8?B?#{Base64.strict_encode64(str.encode('UTF-8'))}?="
  end

  # Generiert eine eindeutige RFC-2822-Message-ID.
  def generate_message_id(from_address)
    domain = from_address.to_s.split('@').last.presence || 'helpdesk.local'
    "<#{SecureRandom.uuid}@#{domain}>"
  end

  def find_issue
    @issue = Issue.find(params[:issue_id])
    @project = @issue.project
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  def authorize_reply
    deny_access unless User.current.allowed_to?(:send_helpdesk_reply, @project)
  end
end
