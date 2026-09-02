# Prueft asynchron, ob die Erstmail eines Tickets genug Informationen enthaelt,
# und fordert den Kunden bei Bedarf automatisch zur Ergaenzung auf.
#
# Wird aus dem MailProcessor nach der Ingestion via perform_later angestossen,
# damit weder die Regelauswertung noch (im KI-Modus) die Modell-Latenz den
# Mailabruf blockiert. Selbst-enthaltend: laedt alle Objekte anhand der IDs neu
# und prueft saemtliche Schalter erneut, bevor irgendetwas nach aussen geht.
#
# Fehler werden geloggt und nicht weitergeworfen — die Mailverarbeitung ist zu
# diesem Zeitpunkt bereits abgeschlossen, und eine misslungene Pruefung darf ein
# Ticket niemals beschaedigen.
class HelpdeskCompletenessJob < ActiveJob::Base
  queue_as :default

  # Mehr Text braucht die Pruefung nicht, und der KI-Modus soll an einem langen
  # weitergeleiteten Verlauf nicht unnoetig Token verbrennen.
  MAX_INPUT_CHARS = 8_000

  # force: true = manueller Neuanlauf durch einen Bearbeiter. Ueberspringt die
  # Wiederholungssperre, nicht aber die Aktivierungsschalter.
  def perform(issue_id, message_id: nil, force: false)
    settings = Setting.plugin_redmine_expert_helpdesk
    unless settings['info_request_enabled'].to_s == '1'
      return log(:debug, "global deaktiviert (issue ##{issue_id})")
    end

    issue = Issue.find_by(:id => issue_id)
    return if issue.nil?

    ps = HelpdeskProjectSetting.for_project(issue.project)
    unless ps.info_request_enabled?
      return log(:debug, "im Projekt #{issue.project.identifier} deaktiviert")
    end

    ticket_info = HelpdeskTicketInfo.for_issue(issue)
    if !force && ticket_info&.info_request_sent?
      return log(:info, "Rueckfrage zu ##{issue.id} bereits gesendet - uebersprungen")
    end

    contact = ticket_info&.helpdesk_contact
    mailbox = ticket_info&.helpdesk_mailbox
    if contact.nil? || contact.email.blank? || mailbox.nil?
      return log(:info, "##{issue.id}: kein Kontakt/Postfach verknuepft - uebersprungen")
    end

    message = message_id && HelpdeskMessage.find_by(:id => message_id)
    text    = source_text(issue, message)
    verdict = evaluate(issue, ps, settings, text, mail_attachments(issue, message))
    return if verdict.nil?

    if verdict.complete?
      return log(:debug, "##{issue.id}: Mail als ausreichend bewertet (#{verdict.source})")
    end

    RedmineExpertHelpdesk::InfoRequestMailer.deliver!(
      :issue       => issue,
      :contact     => contact,
      :mailbox     => mailbox,
      :reasons     => verdict.reasons,
      :in_reply_to => message&.message_id
    )

    HelpdeskTicketInfo.record_info_request!(issue)
    apply_status(issue, ps)

    log(:info, "##{issue.id}: Rueckfrage an #{contact.email} gesendet " \
               "(#{verdict.source}, #{verdict.reasons.size} Punkt(e))")
  rescue StandardError => e
    Rails.logger.error("[helpdesk][info_request] Pruefung fehlgeschlagen " \
                       "(##{issue_id}): #{e.class}: #{e.message}")
  end

  private

  # Liefert ein Verdict oder nil, wenn der KI-Modus nicht laufen kann. nil heisst
  # immer "nichts tun" — im Zweifel wird der Kunde NICHT angeschrieben.
  def evaluate(issue, ps, settings, text, attachments)
    if ps.info_request_ai_mode?
      ai_verdict(issue, ps, settings, text, attachments)
    else
      RedmineExpertHelpdesk::CompletenessCheck.evaluate(
        :text => text, :attachments => attachments, :setting => ps
      )
    end
  end

  def ai_verdict(issue, ps, settings, text, attachments)
    unless RedmineExpertHelpdesk::AiFeatures.ai_enabled?
      log(:info, "##{issue.id}: KI-Modus, aber KI global deaktiviert")
      return nil
    end

    client = RedmineExpertHelpdesk::AiClient.new(settings)
    unless client.configured?
      log(:warn, "##{issue.id}: KI-Modus, aber KI nicht konfiguriert")
      return nil
    end

    if text.blank?
      log(:debug, "##{issue.id}: kein auswertbarer Text")
      return nil
    end

    prompt = ps.effective_info_request_prompt.presence ||
             RedmineExpertHelpdesk::CompletenessCheck::DEFAULT_AI_PROMPT

    # Der Prompt fordert Screenshots/Fotos an - ohne das Anhang-Inventar wuerde das
    # Modell auch dann eines verlangen, wenn der Kunde laengst eines mitgeschickt
    # hat. Die Liste wird NACH dem Kuerzen angehaengt, damit sie nie wegfaellt.
    input = text.first(MAX_INPUT_CHARS) +
            RedmineExpertHelpdesk::CompletenessCheck.attachment_inventory(attachments, ps)

    raw = client.summarize(
      prompt, input, [],
      :log_context => { :request_type => 'completeness',
                        :project_id => issue.project_id, :issue_id => issue.id }
    )
    RedmineExpertHelpdesk::CompletenessCheck.parse_ai_verdict(raw)
  rescue RedmineExpertHelpdesk::AiClient::AiError => e
    # Fail closed: ohne belastbares Urteil geht keine Mail an den Kunden.
    log(:warn, "##{issue.id}: KI-Aufruf fehlgeschlagen, keine Rueckfrage: #{e.message}")
    nil
  end

  # Text der Erstmail: bevorzugt aus der archivierten .eml (dort steht der
  # Originaltext ohne Redmine-Nachbearbeitung), sonst die Ticketbeschreibung.
  def source_text(issue, message)
    eml = message&.eml_attachment
    if eml && eml.diskfile && File.exist?(eml.diskfile)
      text = plain_text_from_eml(eml.diskfile)
      return text if text.present?
    end
    issue.description.to_s
  end

  def plain_text_from_eml(path)
    mail = Mail.read(path)
    if mail.multipart?
      part = mail.text_part
      return part.decoded.to_s if part

      html = mail.html_part
      return ActionView::Base.full_sanitizer.sanitize(html.decoded.to_s) if html

      ''
    else
      mail.body.decoded.to_s
    end
  rescue StandardError => e
    log(:warn, ".eml konnte nicht gelesen werden: #{e.message}")
    nil
  end

  # Die echten Mailanhaenge des Tickets — ohne die von uns selbst angehaengte
  # Original-.eml, die sonst jede Mail "mit Screenshot" aussehen liesse.
  def mail_attachments(issue, message)
    exclude_id = message&.eml_attachment_id
    issue.attachments.to_a.reject do |a|
      a.id == exclude_id || a.description == 'Original E-Mail'
    end
  end

  # Optionaler Statuswechsel ("Warten auf Kunde"). validate => false wie in
  # MailProcessor#apply_new_issue_defaults: der Workflow des Bearbeiters darf
  # einen automatischen Statuswechsel nicht blockieren.
  def apply_status(issue, ps)
    return if ps.info_request_status_id.blank?
    return if issue.status_id == ps.info_request_status_id

    issue.reload
    issue.status_id = ps.info_request_status_id
    issue.save(:validate => false)
  rescue StandardError => e
    log(:warn, "##{issue.id}: Status konnte nicht gesetzt werden: #{e.message}")
  end

  def log(level, message)
    Rails.logger.public_send(level, "[helpdesk][info_request] #{message}")
    nil
  end
end
