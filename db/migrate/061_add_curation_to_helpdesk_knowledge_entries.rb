# Curation trail of a knowledge-base entry, written by the "Knowledge base" project tab.
#
# curated_at marks an entry a person has edited, approved or rejected: the ingest job
# re-extracts on every close, so without this flag a reopened-and-closed ticket would
# silently replace a corrected text with the model's original mistake.
class AddCurationToHelpdeskKnowledgeEntries < ActiveRecord::Migration[6.1]
  def change
    unless column_exists?(:helpdesk_knowledge_entries, :updated_by_id)
      add_column :helpdesk_knowledge_entries, :updated_by_id, :integer
    end

    unless column_exists?(:helpdesk_knowledge_entries, :curated_at)
      add_column :helpdesk_knowledge_entries, :curated_at, :datetime
    end
  end
end
