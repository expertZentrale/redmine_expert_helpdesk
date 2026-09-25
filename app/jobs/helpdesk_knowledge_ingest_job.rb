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
    return unless RedmineExpertHelpdesk::AiFeatures.kb_enabled?

    issue = Issue.find_by(:id => issue_id)
    return unless issue && issue.closed?

    ps = HelpdeskProjectSetting.for_project(issue.project)
    return unless force || ps.kb_ingest_auto? || ps.kb_ingest_manual?

    store  = RedmineExpertHelpdesk::KnowledgeStore.for(settings)
    client = RedmineExpertHelpdesk::AiClient.new(settings)
    return unless client.configured? && client.embed_configured? && store.configured?

    entry = HelpdeskKnowledgeEntry.find_or_initialize_by(:issue_id => issue.id)
    # A person's verdict (edited/approved/rejected in the KB tab) outranks a fresh
    # extraction: a reopened-and-closed ticket must not overwrite it. Only an explicit
    # manual ingest (force) replaces it.
    return if !force && entry.persisted? && (entry.curated? || entry.rejected?)

    result = RedmineExpertHelpdesk::KnowledgeExtractor.new(settings).extract(issue)
    return unless result

    saved = false
    was_indexed = false
    HelpdeskKnowledgeEntry.transaction do
      # The extraction takes seconds; a person may have curated the row meanwhile.
      # Re-check under a row lock so the verdict cannot be overwritten.
      entry.lock! if entry.persisted?
      unless !force && entry.persisted? && (entry.curated? || entry.rejected?)
        was_indexed = entry.point_id.present?

        entry.project_id    = issue.project_id
        entry.problem       = result.problem
        entry.solution      = result.solution
        entry.input_tokens  = result.usage && result.usage[:input]
        entry.output_tokens = result.usage && result.usage[:output]
        # Fresh machine text: the previous person's verdict no longer applies to it.
        entry.updated_by_id = nil
        entry.curated_at    = nil

        entry.status =
          if !result.has_solution then 'skipped'
          elsif force || ps.kb_ingest_auto? then 'approved'
          else 'pending'
          end
        entry.save!
        saved = true
      end
    end
    return unless saved

    if entry.approved?
      index!(store, client, entry)
    elsif was_indexed
      # Previously searchable, now not: drop the stale point.
      HelpdeskKnowledgeEntry.unindex(entry)
    end
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
