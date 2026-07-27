# Erzeugt asynchron eine KI-Zusammenfassung einer eingehenden Helpdesk-Mail und
# haengt sie als private (interne) Journal-Notiz an das Ticket. Wird aus dem
# MailProcessor nach der Ingestion via perform_later angestossen, damit KI-Latenz
# und -Fehler den Mailabruf nicht blockieren.
#
# Selbst-enthaltend: laedt alle noetigen Objekte anhand der IDs neu und prueft
# Aktivierung/Umfang, bevor ein externer Call erfolgt. Fehler werden geloggt und
# nicht weitergeworfen (die Mailverarbeitung ist bereits abgeschlossen).
require 'base64'

class HelpdeskAiSummaryJob < ActiveJob::Base
  include ActionView::Helpers::NumberHelper

  queue_as :default

  MAX_IMAGES         = 4
  MAX_IMAGE_BYTES    = 4 * 1024 * 1024
  MAX_ATT_TEXT_BYTES = 20_000
  PDF_PAGE_LIMIT     = 10

  TEXT_CONTENT_TYPES = %w[text/plain text/csv text/markdown text/xml application/xml
                          application/json message/rfc822].freeze
  TEXT_EXTENSIONS    = %w[txt csv log md json xml eml].freeze

  # force: true = manuelles Neu-Erzeugen aus dem Ticket. Ueberspringt die
  # projektspezifische Aktivierung und den Umfang (der Bearbeiter fordert es aktiv
  # an); globale Aktivierung + Konfiguration werden weiterhin geprueft.
  def perform(issue_id, journal_id: nil, message_id: nil, force: false)
    settings = Setting.plugin_redmine_expert_helpdesk
    return unless settings['ai_enabled'].to_s == '1'

    issue = Issue.find_by(:id => issue_id)
    return unless issue

    ps = HelpdeskProjectSetting.for_project(issue.project)
    journal  = journal_id && Journal.find_by(:id => journal_id)
    is_reply = journal.present?

    unless force
      return unless ps.ai_summary_enabled?
      return if is_reply && !ps.ai_summary_for_replies?
    end

    client = RedmineExpertHelpdesk::AiClient.new(settings)
    return unless client.configured?

    message      = message_id && HelpdeskMessage.find_by(:id => message_id)
    base_text    = if ps.ai_include_journal?
                     journal_text(issue, ps)
                   else
                     source_text(issue, journal, message)
                   end
    attachments  = mail_attachments(issue, journal, message&.eml_attachment_id)
    user_text, image_parts = build_input(base_text, attachments, ps, settings)
    return if user_text.blank? && image_parts.empty?

    prompt  = ps.effective_ai_prompt.presence || RedmineExpertHelpdesk::AiClient::DEFAULT_PROMPT
    system  = RedmineExpertHelpdesk::TemplateRenderer.render(prompt, :issue => issue, :contact => contact_for(issue))

    # RAG: aehnliche geloeste Tickets aus der projekteigenen Wissensbasis.
    # Fuer die Suche einen fokussierten Query nutzen (Betreff + Textkern statt des
    # anhangslastigen user_text), das erhoeht die Aehnlichkeit zu den destillierten
    # Wissensbasis-Eintraegen.
    query_text = "#{issue.subject}\n#{base_text}"
    proposals = retrieve_proposals(issue, ps, settings, client, query_text)
    if proposals.any?
      persist_proposals(issue, proposals) if ps.kb_show_in_sidebar?
      system += kb_context_block(proposals) if ps.kb_show_in_summary?
    end

    summary = client.summarize(system, user_text, image_parts,
                               :log_context => { :request_type => 'summary',
                                                 :project_id => issue.project_id, :issue_id => issue.id })

    journal = create_note(issue, summary)
    record_summary(issue, journal, client)
  rescue RedmineExpertHelpdesk::AiClient::AiError => e
    # Antwort-Body des Providers mitloggen – dort steht der eigentliche Grund
    # (z. B. falsches Modell, nicht unterstuetzter Parameter, Kontextlaenge).
    detail = e.body.to_s.gsub(/\s+/, ' ').strip
    detail = "#{detail[0, 500]}…" if detail.length > 500
    msg = "[helpdesk][ai] Zusammenfassung fehlgeschlagen (Issue ##{issue_id}): #{e.message}"
    msg += " – #{detail}" if detail.present?
    Rails.logger.warn(msg)
  rescue => e
    Rails.logger.warn("[helpdesk][ai] Unerwarteter Fehler (Issue ##{issue_id}): #{e.class}: #{e.message}")
  end

  private

  # Volltext der Mail: bevorzugt der komplette Klartext aus der .eml (ganzer
  # Verlauf), Fallback auf die Journal-Notiz bzw. Ticket-Beschreibung.
  def source_text(issue, journal, message)
    eml = message&.eml_attachment
    if eml && eml.diskfile && File.exist?(eml.diskfile)
      text = plain_text_from_eml(eml.diskfile)
      return text if text.present?
    end
    (journal ? journal.notes : issue.description).to_s
  end

  # Kompletter Ticketverlauf: Beschreibung + Journal-Notizen. Private Notizen nur,
  # wenn projektseitig erlaubt. Eigene KI-Zusammenfassungen werden ausgeschlossen,
  # damit die Zusammenfassung nicht rekursiv frueheren KI-Text einspeist.
  def journal_text(issue, ps)
    own = HelpdeskAiSummary.where(:issue_id => issue.id).pluck(:journal_id).compact.to_set
    parts = []
    parts << issue.description.to_s if issue.description.present?

    issue.journals.order(:created_on).each do |j|
      next if j.notes.blank?
      next if j.private_notes? && !ps.ai_include_private_notes?
      next if own.include?(j.id)

      author = j.user ? j.user.name : '?'
      stamp  = j.created_on ? j.created_on.strftime('%d.%m.%Y %H:%M') : ''
      parts << "--- #{author} (#{stamp}) ---\n#{j.notes}"
    end

    parts.join("\n\n")
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
  rescue => e
    Rails.logger.warn("[helpdesk][ai] .eml konnte nicht gelesen werden: #{e.message}")
    nil
  end

  # Anhaenge dieser Mail (ohne die von uns angehaengte Original-.eml).
  def mail_attachments(issue, journal, exclude_id)
    list =
      if journal
        ids = journal.details.select { |d| d.property == 'attachment' }.map { |d| d.prop_key.to_i }
        Attachment.where(:id => ids).to_a
      else
        issue.attachments.to_a
      end
    list.reject { |a| a.id == exclude_id || a.description == 'Original E-Mail' }
  end

  # Baut den User-Text (Mailinhalt + optionale Anhang-Infos) und die Bildliste
  # entsprechend der projektspezifischen Anhang-Auswahl. Truncated auf das Limit.
  def build_input(base_text, attachments, ps, settings)
    max_chars = settings['ai_max_input_chars'].to_i
    max_chars = 12_000 unless max_chars.positive?

    parts = [base_text.to_s]
    image_parts = []

    if attachments.any? && ps.ai_attach_metadata?
      meta = attachments.map { |a| " - #{a.filename} (#{a.content_type}, #{number_to_human_size(a.filesize)})" }
      parts << "\n[Anhaenge:\n#{meta.join("\n")}\n]"
    end

    if attachments.any? && ps.ai_attach_text?
      attachments.each do |a|
        txt = extract_text(a)
        parts << "\n[Anhang #{a.filename} – extrahierter Text:]\n#{txt}" if txt.present?
      end
    end

    if ps.ai_attach_images?
      attachments.select { |a| a.content_type.to_s.start_with?('image/') }.first(MAX_IMAGES).each do |a|
        next unless a.diskfile && File.exist?(a.diskfile) && a.filesize.to_i <= MAX_IMAGE_BYTES

        image_parts << { :content_type => a.content_type, :data => Base64.strict_encode64(File.binread(a.diskfile)) }
      end
    end

    user_text = parts.join("\n").strip
    user_text = user_text[0, max_chars] if user_text.length > max_chars
    [user_text, image_parts]
  end

  # Textextraktion aus Anhaengen: Text-basierte Typen direkt, PDF via pdf-reader
  # (optional; ohne das Gem wird PDF-Text uebersprungen). Bilder werden hier nicht
  # gelesen (dafuer ist die Vision-Option zustaendig).
  def extract_text(att)
    return nil unless att.diskfile && File.exist?(att.diskfile)

    ct  = att.content_type.to_s
    ext = File.extname(att.filename.to_s).delete('.').downcase

    if ct.start_with?('text/') || TEXT_CONTENT_TYPES.include?(ct) || TEXT_EXTENSIONS.include?(ext)
      File.read(att.diskfile, MAX_ATT_TEXT_BYTES).to_s.scrub(' ')
    elsif ct == 'application/pdf' || ext == 'pdf'
      extract_pdf(att.diskfile)
    end
  rescue => e
    Rails.logger.warn("[helpdesk][ai] Textextraktion fehlgeschlagen (#{att.filename}): #{e.message}")
    nil
  end

  def extract_pdf(path)
    require 'pdf-reader'
    reader = PDF::Reader.new(path)
    reader.pages.first(PDF_PAGE_LIMIT).map(&:text).join("\n")
  rescue LoadError
    nil # pdf-reader nicht verfuegbar -> PDF-Text ueberspringen
  end

  def contact_for(issue)
    HelpdeskTicketInfo.find_by(:issue_id => issue.id)&.helpdesk_contact
  end

  # RAG: aehnliche geloeste Tickets aus der Wissensbasis DES PROJEKTS holen
  # (strikte Isolation ueber den Store). Liefert nur, wenn genug Treffer ueber
  # dem Score-Schwellwert liegen. Fehler blockieren die Zusammenfassung nicht.
  def retrieve_proposals(issue, ps, settings, client, query_text)
    return [] unless settings['kb_enabled'].to_s == '1'
    return [] unless ps.kb_show_in_summary? || ps.kb_show_in_sidebar?
    return [] if query_text.blank?

    store = RedmineExpertHelpdesk::KnowledgeStore.for(settings)
    return [] unless store.configured? && client.embed_configured?

    top_k = settings['kb_top_k'].to_i
    top_k = 3 unless top_k.positive?
    min_score   = settings['kb_min_score'].to_f
    min_results = settings['kb_min_results'].to_i
    min_results = 1 unless min_results.positive?

    vec  = client.embed(query_text.to_s[0, 8000],
                        :log_context => { :request_type => 'kb_retrieve',
                                          :project_id => issue.project_id, :issue_id => issue.id })
    hits = store.search(issue.project_id, vec, top_k)
    hits = hits.select { |h| h[:score].to_f >= min_score }
    hits = hits.reject { |h| (h[:payload] || {})['issue_id'].to_i == issue.id }
    hits.size >= min_results ? hits : []
  rescue => e
    Rails.logger.warn("[helpdesk][kb] Retrieval fehlgeschlagen (Issue ##{issue.id}): #{e.message}")
    []
  end

  def persist_proposals(issue, proposals)
    HelpdeskKbProposal.where(:issue_id => issue.id).delete_all
    proposals.each do |h|
      p = h[:payload] || {}
      HelpdeskKbProposal.create!(
        :issue_id        => issue.id,
        :source_issue_id => p['issue_id'],
        :score           => h[:score],
        :problem         => p['problem'],
        :solution        => p['solution']
      )
    end
  end

  def kb_context_block(proposals)
    lines = proposals.each_with_index.map do |h, i|
      p = h[:payload] || {}
      "#{i + 1}. (Ticket ##{p['issue_id']}) Problem: #{p['problem']}\n   Loesung: #{p['solution']}"
    end
    "\n\n---\nAehnliche frueher geloeste Faelle aus der Wissensbasis:\n#{lines.join("\n")}\n\n" \
      'Wenn einer dieser Faelle zum aktuellen Anliegen passt, ergaenze am Ende der Zusammenfassung ' \
      'einen Abschnitt "Loesungsvorschlag" mit dem passenden Vorgehen und nenne die Ticketnummer(n). ' \
      'Passt nichts, lasse den Abschnitt weg.'
  end

  def create_note(issue, summary)
    body = "🤖 #{I18n.t(:label_helpdesk_ai_summary)}\n\n#{summary}"
    journal = Journal.new(
      :journalized   => issue,
      :user          => User.anonymous,
      :notes         => body,
      :private_notes => true
    )
    journal.notify = false if journal.respond_to?(:notify=)
    journal.save!
    journal
  end

  # Protokolliert Provider/Modell + Token-Verbrauch fuer die Header-Anzeige.
  def record_summary(issue, journal, client)
    usage = client.last_usage || {}
    HelpdeskAiSummary.create!(
      :issue_id      => issue.id,
      :journal_id    => journal&.id,
      :provider      => client.provider,
      :model         => client.model,
      :input_tokens  => usage[:input],
      :output_tokens => usage[:output]
    )
  rescue => e
    Rails.logger.warn("[helpdesk][ai] Token-Protokoll konnte nicht gespeichert werden: #{e.message}")
  end
end
