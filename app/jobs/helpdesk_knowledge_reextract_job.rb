# Re-runs the extraction of a project's knowledge-base entries after its detail
# level changed (button on the "Knowledge base" tab, rake kb_reextract). Fans
# out one ingest job per entry, so a failing ticket only costs its own entry.
#
# Curated and rejected entries are left alone: a person's verdict outranks a
# fresh extraction, exactly as on re-close. By default only entries extracted at
# a different level than the project's effective one are picked; all: true
# re-extracts every eligible entry (e.g. after editing the prompt text).
class HelpdeskKnowledgeReextractJob < ActiveJob::Base
  queue_as :default

  def perform(project_id, all: false)
    count = self.class.enqueue(project_id, :all => all)
    Rails.logger.info("[helpdesk][kb] Project ##{project_id}: #{count.to_i} entries queued for re-extraction")
  end

  # Entries a re-extraction would touch. NULL extract_detail = extracted before
  # detail levels existed, i.e. at 'general'.
  def self.scope_for(project_id, all: false)
    # Only tickets that are still closed: the ingest job skips reopened and
    # deleted ones, so counting them would never reach zero (and the tab would
    # never offer re-extracting all). A later re-close ingests them anyway.
    scope = HelpdeskKnowledgeEntry.where(:project_id => project_id, :curated_at => nil)
                                  .where.not(:status => 'rejected')
                                  .joins(:issue => :status).where(:issue_statuses => { :is_closed => true })
    return scope if all || !HelpdeskKnowledgeEntry.column_names.include?('extract_detail')

    project = Project.find_by(:id => project_id)
    return scope.none unless project

    level = HelpdeskProjectSetting.for_project(project).effective_kb_extract_detail
    if level == RedmineExpertHelpdesk::KnowledgeExtractor::DEFAULT_DETAIL
      scope.where.not(:extract_detail => [nil, level])
    else
      scope.where(:extract_detail => nil).or(scope.where.not(:extract_detail => level))
    end
  end

  # Returns the number of queued entries, nil when the knowledge base is not usable.
  def self.enqueue(project_id, all: false)
    return nil unless RedmineExpertHelpdesk::AiFeatures.kb_ready?

    count = 0
    scope_for(project_id, :all => all).find_each do |entry|
      HelpdeskKnowledgeIngestJob.perform_later(entry.issue_id, :reextract => true)
      count += 1
    end
    count
  end
end
