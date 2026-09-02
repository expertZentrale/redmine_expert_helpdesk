# Checks asynchronously whether the first mail of a ticket carries enough
# information and, when it does not, asks the customer to fill in the rest.
#
# Fired from MailProcessor after ingestion via perform_later, so that neither the
# rule evaluation nor (in AI mode) the model latency blocks the mail fetch.
# Self-contained: reloads every object by id and re-checks every switch before
# anything leaves the box.
#
# Errors are logged and never re-raised — mail processing is already finished at
# this point, and a failed check must never damage a ticket.
class HelpdeskCompletenessJob < ActiveJob::Base
  queue_as :default

  # The check needs no more text than this, and the AI mode should not burn tokens
  # on a long forwarded thread.
  MAX_INPUT_CHARS = 8_000

  # force: true = manual re-run by an agent. Skips the repeat guard, but not the
  # activation switches.
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

  # Returns a Verdict, or nil when the AI mode cannot run. nil always means "do
  # nothing" — when in doubt the customer is NOT mailed.
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

    # The prompt asks for screenshots/photos - without the attachment inventory the
    # model would demand one even when the customer already sent it. The list is
    # appended AFTER truncating, so it can never be cut off.
    input = text.first(MAX_INPUT_CHARS) +
            RedmineExpertHelpdesk::CompletenessCheck.attachment_inventory(attachments, ps)

    raw = client.summarize(
      prompt, input, [],
      :log_context => { :request_type => 'completeness',
                        :project_id => issue.project_id, :issue_id => issue.id }
    )
    RedmineExpertHelpdesk::CompletenessCheck.parse_ai_verdict(raw)
  rescue RedmineExpertHelpdesk::AiClient::AiError => e
    # Fail closed: without a dependable verdict no mail goes to the customer.
    log(:warn, "##{issue.id}: KI-Aufruf fehlgeschlagen, keine Rueckfrage: #{e.message}")
    nil
  end

  # Text of the first mail: preferably from the archived .eml (which holds the
  # original text without Redmine's post-processing), else the issue description.
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

  # The real mail attachments of the ticket — without the Original .eml we attach
  # ourselves, which would otherwise make every mail look like it had evidence.
  def mail_attachments(issue, message)
    exclude_id = message&.eml_attachment_id
    issue.attachments.to_a.reject do |a|
      a.id == exclude_id || a.description == 'Original E-Mail'
    end
  end

  # Optional status change ("waiting for customer"). validate => false as in
  # MailProcessor#apply_new_issue_defaults: an agent's workflow must not block an
  # automatic status change.
  def apply_status(issue, ps)
    status_id = ps.info_request_status_id.to_i
    return unless status_id.positive?
    return if issue.status_id == status_id

    # Checked again here, not just on input: the status may have been deleted
    # since it was configured, and save(:validate => false) would happily write a
    # dangling id and leave the ticket in a status that no longer exists.
    unless IssueStatus.exists?(status_id)
      return log(:warn, "##{issue.id}: konfigurierter Status #{status_id} existiert nicht mehr")
    end

    issue.reload
    issue.status_id = status_id
    issue.save(:validate => false)
  rescue StandardError => e
    log(:warn, "##{issue.id}: Status konnte nicht gesetzt werden: #{e.message}")
  end

  def log(level, message)
    Rails.logger.public_send(level, "[helpdesk][info_request] #{message}")
    nil
  end
end
