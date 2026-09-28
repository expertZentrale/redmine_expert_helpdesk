# Seeds the synthetic "KB Reranker Demo" project from dataset.json: one closed ticket and
# one approved knowledge-base entry per dataset entry, embedded through the plugin's own
# HelpdeskKnowledgeIngestJob.index_entry (no LLM extraction). Idempotent - re-running
# updates the texts and re-embeds them. See README.md in this directory.
require 'json'

dir   = ENV['DEMO_DIR'] || '/demo'
data  = JSON.parse(File.read(File.join(dir, 'dataset.json')))
admin = User.where(:admin => true, :status => User::STATUS_ACTIVE).order(:id).first
User.current = admin

abort 'Knowledge base is not ready (kb_enabled, vector store, embeddings).' unless RedmineExpertHelpdesk::AiFeatures.kb_ready?

pd = data['project']
project = Project.find_by(:identifier => pd['identifier']) || begin
  p = Project.new(:name => pd['name'], :identifier => pd['identifier'], :is_public => false,
                  :description => 'Synthetic demo data for the knowledge-base reranker documentation.')
  p.trackers = Tracker.sorted.to_a.first(1)
  p.save!
  p
end
project.enable_module!(:helpdesk)
tracker   = project.trackers.first
closed    = IssueStatus.where(:is_closed => true).order(:position).first
open_st   = IssueStatus.where(:is_closed => false).order(:position).first
priority  = IssuePriority.default || IssuePriority.first

indexed = 0
data['entries'].each do |e|
  issue = Issue.where(:project_id => project.id, :subject => e['subject']).first
  unless issue
    issue = Issue.create!(:project => project, :tracker => tracker, :author => admin, :priority => priority,
                          :subject => e['subject'], :description => e['problem'], :status => open_st)
    # Closed by column: going through the status change would enqueue the ingest job,
    # whose LLM extraction would replace the curated demo texts.
    issue.update_columns(:status_id => closed.id, :closed_on => Time.current)
  end
  entry = HelpdeskKnowledgeEntry.find_or_initialize_by(:issue_id => issue.id)
  entry.project_id = project.id
  entry.problem    = e['problem']
  entry.solution   = e['solution']
  entry.status     = 'approved'
  entry.save!
  indexed += 1 if HelpdeskKnowledgeIngestJob.index_entry(entry)
end

# Entries removed from or renamed in dataset.json: drop their knowledge row, vector point
# and ticket, so a re-seed searches exactly the current dataset.
subjects = data['entries'].map { |e| e['subject'] } + ['Demo query ticket']
removed = 0
Issue.where(:project_id => project.id).where.not(:subject => subjects).find_each do |stale|
  if (entry = HelpdeskKnowledgeEntry.find_by(:issue_id => stale.id))
    HelpdeskKnowledgeEntry.unindex(entry) if entry.point_id.present?
    entry.destroy
  end
  stale.destroy
  removed += 1
end

# The ticket every demo query is searched "from" (it is not in the knowledge base).
unless Issue.where(:project_id => project.id, :subject => 'Demo query ticket').exists?
  Issue.create!(:project => project, :tracker => tracker, :author => admin, :priority => priority,
                :status => open_st, :subject => 'Demo query ticket', :description => 'placeholder')
end

puts "Project #{project.identifier} (##{project.id}): #{indexed}/#{data['entries'].size} entries indexed, #{removed} stale removed."
