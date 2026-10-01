# What the sidebar needs to show the same choice as the AI summary.
# - ai_verdict: did the summary cite this proposal as fitting? true / false,
#   nil when no summary judged it (summary without knowledge base, older rows).
# - reranked: was the order decided by the cross-encoder? false when one is
#   configured but failed, nil when none is configured.
class AddAiVerdictToHelpdeskKbProposals < ActiveRecord::Migration[6.1]
  def change
    add_column :helpdesk_kb_proposals, :ai_verdict, :boolean unless column_exists?(:helpdesk_kb_proposals, :ai_verdict)
    add_column :helpdesk_kb_proposals, :reranked, :boolean unless column_exists?(:helpdesk_kb_proposals, :reranked)
  end
end
