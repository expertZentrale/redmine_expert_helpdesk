# Nimmt ein abgeschlossenes Ticket in die Wissensbasis auf: extrahiert
# {Problem, Loesung} per KI, legt einen HelpdeskKnowledgeEntry an (auto -> approved,
# manual -> pending) und indexiert approved-Eintraege im Vektor-Store.
# Fehler brechen nichts ab (nur Logging), da async nach Ticket-Abschluss.
class HelpdeskKnowledgeIngestJob < ActiveJob::Base
  queue_as :default

  # force: true = manuelle Aufnahme aus dem Ticket -> sofort approved+indexiert,
  # unabhaengig vom Projekt-Modus.
  # reextract: true = re-run the extraction of an existing entry (detail level
  # changed). Curated/rejected entries stay untouched and the entry keeps its
  # status: in 'manual' mode an approved entry would otherwise fall back to
  # pending and drop out of the vector store.
  def perform(issue_id, force: false, reextract: false, requested_at: nil)
    settings = Setting.plugin_redmine_expert_helpdesk
    return unless RedmineExpertHelpdesk::AiFeatures.kb_enabled?

    issue = Issue.find_by(:id => issue_id)
    return unless issue && issue.closed?

    ps = HelpdeskProjectSetting.for_project(issue.project)
    # reextract is an explicit request for existing entries and also applies
    # while the project no longer contributes new ones (it never creates a row).
    return unless force || reextract || ps.kb_ingest_auto? || ps.kb_ingest_manual?

    store  = RedmineExpertHelpdesk::KnowledgeStore.for(settings)
    client = RedmineExpertHelpdesk::AiClient.new(settings)
    return unless client.configured? && client.embed_configured? && store.configured?

    entry = HelpdeskKnowledgeEntry.find_or_initialize_by(:issue_id => issue.id)
    # A person's verdict (edited/approved/rejected in the KB tab) outranks a fresh
    # extraction: a reopened-and-closed ticket must not overwrite it. Only an explicit
    # manual ingest (force) replaces it.
    return if !force && entry.persisted? && (entry.curated? || entry.rejected?)
    return if reextract && !entry.persisted?
    # Each entry costs an AI call: a double-submit or a second admin queues the
    # same entries again. Claim the row atomically (works across processes) and
    # only if untouched since the request; a duplicate job finds it claimed.
    return if reextract && requested_at && !claim_for_reextract(entry, requested_at)

    # The row as claimed. The AI call takes seconds; a normal re-ingest or a
    # newer re-extraction may write the row meanwhile, and this result must not
    # replace that newer one (checked again under the row lock below).
    claimed = claim_snapshot(entry.reload) if reextract && requested_at

    result = RedmineExpertHelpdesk::KnowledgeExtractor.new(settings).extract(issue)
    return unless result
    # Re-extraction promises to keep an entry's status. A run that finds no
    # solution (often a one-off miss of the model) must not demote an approved
    # or pending entry and pull it out of the search: keep the old text.
    return if reextract && !result.has_solution && %w[approved pending].include?(entry.status)

    saved = false
    was_indexed = false
    HelpdeskKnowledgeEntry.transaction do
      # The extraction takes seconds; a person may have curated the row meanwhile.
      # Re-check under a row lock so the verdict cannot be overwritten.
      entry.lock! if entry.persisted?
      if claimed && claim_snapshot(entry) != claimed
        Rails.logger.info("[helpdesk][kb] Re-extraction of entry ##{entry.id} dropped: row changed during the AI call")
        next
      end
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

        entry.extract_detail = result.detail if entry.has_attribute?(:extract_detail)
        entry.status =
          if !result.has_solution then 'skipped'
          elsif reextract && %w[approved pending].include?(entry.status_was) then entry.status_was
          elsif force || ps.kb_ingest_auto? then 'approved'
          else 'pending'
          end
        # Keep the claim: a plain save stamps "now", which a column without
        # fractional seconds rounds back into the request's second. lock! has
        # already reloaded the claim time, so assigning it again changes
        # nothing - the timestamp has to be switched off explicitly.
        claimed = reextract && requested_at
        entry.updated_at = claim_time(requested_at) if claimed
        entry.save!(:touch => !claimed)
        saved = true
      end
    end
    return unless saved

    if entry.approved?
      index!(store, client, entry)
      fence_index(entry)
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

  # The claim moves updated_at strictly past requested_at - by at least a second,
  # since a column without fractional seconds would otherwise round the claim
  # back to the request's second and let a duplicate through.
  def claim_for_reextract(entry, requested_at)
    HelpdeskKnowledgeEntry.where(:id => entry.id).where('updated_at <= ?', requested_at)
                          .update_all(:updated_at => claim_time(requested_at)) == 1
  end

  # updated_at alone can miss a write within the same second on a column
  # without fractional seconds; the content fields cannot.
  def claim_snapshot(entry)
    entry.attributes.slice('updated_at', 'status', 'problem', 'solution', 'curated_at', 'extract_detail')
  end

  # Strictly past requested_at, by at least a second (see the save above).
  def claim_time(requested_at)
    [Time.current, requested_at + 1.second].max
  end

  # The embedding call runs after the row lock is gone. A person who rejected or
  # edited the entry meanwhile may have removed or re-embedded the point first;
  # this upsert would then bring back the stale machine text. Compare with the
  # row as it is now and undo or redo accordingly.
  def fence_index(entry, attempts = 3)
    indexed = entry
    attempts.times do
      current = HelpdeskKnowledgeEntry.find_by(:id => entry.id)
      # Deleted meanwhile: the destroy removed the point before this upsert.
      return HelpdeskKnowledgeEntry.unindex(indexed) unless current
      return HelpdeskKnowledgeEntry.unindex(current) unless current.approved?
      return if current.problem == indexed.problem && current.solution == indexed.solution

      # The corrective re-embed takes as long as the first one, so the row can
      # change again under it: check once more afterwards (bounded).
      # A failed re-embed leaves the stale machine text in the store: remove it
      # rather than treat the attempt as indexed.
      return HelpdeskKnowledgeEntry.unindex(current) unless self.class.index_entry(current)

      indexed = current
    end
    Rails.logger.warn("[helpdesk][kb] Entry ##{entry.id} kept changing during re-indexing; left as last indexed")
  end

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
