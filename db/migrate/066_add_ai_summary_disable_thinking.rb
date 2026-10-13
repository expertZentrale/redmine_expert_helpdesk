# Per-project override for the reasoning ("thinking") mode of AI summaries.
# NULL = follow the central setting, true = disable thinking, false = allow it.
class AddAiSummaryDisableThinking < ActiveRecord::Migration[6.1]
  def change
    return if column_exists?(:helpdesk_project_settings, :ai_summary_disable_thinking)

    add_column :helpdesk_project_settings, :ai_summary_disable_thinking, :boolean
  end
end
