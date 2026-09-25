# Rebuilds one project's vector namespace from the SQL system of record: drops the
# Qdrant collection / pgvector rows and re-embeds every approved entry (no LLM call).
# Clears orphan points and follows an embeddings-model change. Started from the
# "Knowledge base" project tab; the kb_reembed rake task runs it for every project.
class HelpdeskKnowledgeReindexJob < ActiveJob::Base
  queue_as :default

  def perform(project_id)
    self.class.rebuild(project_id)
  end

  # Returns the number of re-indexed entries, or nil when the store is not usable.
  def self.rebuild(project_id)
    settings = Setting.plugin_redmine_expert_helpdesk
    return nil unless RedmineExpertHelpdesk::AiFeatures.kb_enabled?

    store = RedmineExpertHelpdesk::KnowledgeStore.for(settings)
    return nil unless store.configured?

    store.reset!(project_id)
    HelpdeskKnowledgeEntry.where(:project_id => project_id).where.not(:status => 'approved')
                          .update_all(:point_id => nil)
    ok = 0
    HelpdeskKnowledgeEntry.approved.where(:project_id => project_id).find_each do |entry|
      ok += 1 if HelpdeskKnowledgeIngestJob.index_entry(entry)
    end
    Rails.logger.info("[helpdesk][kb] Project ##{project_id} re-indexed: #{ok} entries")
    ok
  rescue => e
    Rails.logger.warn("[helpdesk][kb] Re-index of project ##{project_id} failed: #{e.class}: #{e.message}")
    nil
  end
end
