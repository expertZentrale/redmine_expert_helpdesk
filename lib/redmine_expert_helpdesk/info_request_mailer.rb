# Sends the automatic "please tell us more" mail of the completeness check.
#
# Deliberately a plain lib class, not an ActionMailer: it must follow the
# mailbox's outgoing route (Graph / mailbox SMTP / Redmine SMTP) exactly the way
# the autoresponder does, and ActionMailer knows nothing about those routes.
# The body is plain text, so none of InitMailer's HTML/CID machinery applies.
#
# The customer's answer has to land on the same ticket, so the mail carries
# In-Reply-To/References of the incoming mail (see the comment in
# MailProcessor#send_autoresponder — Graph rejects those headers on JSON sends,
# which is why a full MIME message is built here too).
module RedmineExpertHelpdesk
  class InfoRequestMailer
    # Zentraler Default-Text der Rueckfrage. {{missing_info}} wird durch die
    # aufbereitete Liste der fehlenden Angaben ersetzt; ohne diesen Platzhalter
    # bekommt der Kunde eine Rueckfrage, ohne zu erfahren, was fehlt.
    DEFAULT_BODY = <<~'BODY'.freeze
      Guten Tag {{contact.name}},

      vielen Dank fuer Ihre Nachricht. Wir haben Ihre Anfrage unter der Nummer
      [#{{issue.id}}] aufgenommen.

      Damit wir Ihnen schnell helfen koennen, benoetigen wir noch ein paar Angaben:

      {{missing_info}}

      Bitte antworten Sie einfach auf diese E-Mail. Ihre Antwort wird automatisch
      Ihrer Anfrage zugeordnet.

      Mit freundlichen Gruessen
      Ihr Support-Team
    BODY

    class << self
      # Returns the created HelpdeskMessage, or nil when nothing was sent.
      # Raises nothing the caller has to handle beyond provider errors: the job
      # wraps the call and must not break ingestion.
      def deliver!(issue:, contact:, mailbox:, reasons:, in_reply_to: nil, provider: nil)
        setting  = HelpdeskProjectSetting.for_project(issue.project)
        rendered = render_reasons(reasons)
        context  = { :issue => issue, :contact => contact, :missing_info => rendered }

        subject = TemplateRenderer.render(
          setting.effective_info_request_subject.presence || default_subject(issue),
          context
        )
        body = TemplateRenderer.render(setting.effective_info_request_body, context)

        mail = build_mail(mailbox, contact, subject, body, in_reply_to)

        MailLogger.track(
          :kind => 'info_request', :mailbox => mailbox, :issue => issue,
          :to => contact.email, :subject => subject, :message_id => mail.message_id
        ) { deliver(mail, mailbox, provider) }

        message = HelpdeskMessage.create!(
          :issue            => issue,
          :helpdesk_contact => contact,
          :helpdesk_mailbox => mailbox,
          :direction        => 'out',
          :subject          => subject,
          :sent_at          => Time.current,
          :recipient_to     => contact.email
        )

        add_note(issue, contact, rendered, setting.info_request_note_private?)
        message
      end

      # Reason symbols come from the heuristic rule set and are localised here;
      # AI reasons are already free text from the model and pass through.
      def render_reasons(reasons)
        Array(reasons).map do |reason|
          if reason.is_a?(Symbol)
            I18n.t("text_helpdesk_info_request_reason_#{reason}", :default => reason.to_s)
          else
            reason.to_s
          end
        end.reject(&:blank?).map { |line| "- #{line}" }.join("\n")
      end

      private

      def default_subject(issue)
        "[##{issue.id}] {{issue.subject}}"
      end

      def build_mail(mailbox, contact, subject, body, in_reply_to)
        mail = Mail.new
        mail.from = mailbox.from_address
        # Opt-in only; see HelpdeskMailbox#reply_to_address.
        reply_to_addr = mailbox.reply_to_address
        mail.reply_to = reply_to_addr if reply_to_addr
        mail.to      = contact.email
        mail.subject = subject
        mail.body    = body

        if in_reply_to.present?
          ref_id = "<#{in_reply_to.to_s.delete('<>').strip}>"
          mail['In-Reply-To'] = ref_id
          mail['References']  = ref_id
        end

        mail
      end

      # Same route resolution as MailProcessor#deliver_autoresponder. The optional
      # provider is the receiving session MailProcessor already holds open; the job
      # has none and lets MailProvider build one.
      def deliver(mail, mailbox, provider)
        if mailbox.outgoing_route == 'smtp'
          mail.delivery_method(ActionMailer::Base.delivery_method,
                               ActionMailer::Base.smtp_settings || {})
          mail.deliver!
          # Redmine's relay files nothing in the mailbox itself. No-op for Graph.
          (provider || MailProvider.for(mailbox)).archive_sent(mail.to_s)
        else
          outgoing = if mailbox.outgoing_route == 'mailbox_smtp' && provider
                       provider
                     else
                       MailProvider.outgoing_for(mailbox)
                     end
          outgoing.send_mail_mime(mail.to_s)
        end
      end

      # Protocol note for the agent. Public by default - the customer got the same
      # text by mail anyway, and a shared record avoids asking twice - but a
      # project can keep it internal (info_request_note_visibility).
      def add_note(issue, contact, rendered_reasons, private_note = false)
        Journal.create!(
          :journalized   => issue,
          :user          => User.anonymous,
          :notes         => I18n.t(:note_helpdesk_info_request_sent, :email => contact.email) +
                            (rendered_reasons.present? ? "\n\n#{rendered_reasons}" : ''),
          :private_notes => private_note
        )
      rescue StandardError => e
        Rails.logger.warn("[helpdesk][info_request] Notiz konnte nicht gespeichert werden " \
                          "(##{issue.id}): #{e.message}")
      end
    end
  end
end
