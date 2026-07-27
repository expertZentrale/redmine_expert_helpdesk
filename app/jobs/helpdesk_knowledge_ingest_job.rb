# Nimmt ein abgeschlossenes Ticket in die Wissensbasis auf: extrahiert
# {Problem, Loesung} per KI, legt einen HelpdeskKnowledgeEntry an (auto -> approved,
# manual -> pending) und indexiert approved-Eintraege im Vektor-Store.
# Fehler brechen nichts ab (nur Logging), da async nach Ticket-Abschluss.
class HelpdeskKnowledgeIngestJob < ActiveJob::Base
  queue_as :default

  # force: true = manuelle Aufnahme aus dem Ticket -> sofort approved+indexiert,
  # unabhaengig vom Projekt-Modus.
  def perform(issue_id, force: false)
    settings = Setting.plugin_redmine_expert_helpdesk
    return unless settings['kb_enabled'].to_s == '1'

    issue = Issue.find_by(:id => issue_id)
    return unless issue && issue.closed?

    ps = HelpdeskProjectSetting.for_project(issue.project)
    return unless force || ps.kb_ingest_auto? || ps.kb_ingest_manual?

    store  = RedmineExpertHelpdesk::KnowledgeStore.for(settings)
    client = RedmineExpertHelpdesk::AiClient.new(settings)
    return unless client.configured? && client.embed_configured? && store.configured?

    result = RedmineExpertHelpdesk::KnowledgeExtractor.new(settings).extract(issue)
    return unless result

    entry = HelpdeskKnowledgeEntry.find_or_initialize_by(:issue_id => issue.id)
    entry.project_id    = issue.project_id
    entry.problem       = result.problem
    entry.solution      = result.solution
    entry.input_tokens  = result.usage && result.usage[:input]
    entry.output_tokens = result.usage && result.usage[:output]

    unless result.has_solution
      entry.status = 'skipped'
      entry.save!
      return
    end

    entry.status = (force || ps.kb_ingest_auto?) ? 'approved' : 'pending'
    entry.save!

    index!(store, client, entry) if entry.approved?
  rescue => e
    Rails.logger.warn("[helpdesk][kb] Ingest fehlgeschlagen (Issue ##{issue_id}): #{e.class}: #{e.message}")
  end

  # Von der manuellen Freigabe genutzt: bereits extrahierten Eintrag embedden und
  # in den Vektor-Store schreiben (ohne erneuten LLM-Aufruf).
  def self.index_entry(entry)
    settings = Setting.plugin_redmine_expert_helpdesk
    store  = RedmineExpertHelpdesk::KnowledgeStore.for(settings)
    client = RedmineExpertHelpdesk::AiClient.new(settings)
    return false unless store.configured? && client.embed_configured?

    new.send(:index!, store, client, entry)
    true
  rescue => e
    Rails.logger.warn("[helpdesk][kb] Indexierung fehlgeschlagen (Eintrag ##{entry.id}): #{e.message}")
    false
  end

  private

  def index!(store, client, entry)
    vec = client.embed(entry.problem.to_s,
                       :log_context => { :request_type => 'kb_embed',
                                         :project_id => entry.project_id, :issue_id => entry.issue_id })
    store.ensure_ready!(entry.project_id, vec.size)
    payload = { 'issue_id' => entry.issue_id, 'problem' => entry.problem, 'solution' => entry.solution }
    store.upsert(entry.project_id, entry.id, vec, payload)
    entry.update_columns(:embed_model => client.embed_model, :point_id => entry.id.to_s)
  end
end
