# Per-project control of the AI answer draft ("KI-Antwortvorschlag"):
# a button in the note toolbar that writes a customer-facing reply for the
# ticket, grounded in the project's knowledge base.
#
# - ai_answer_enabled: off by default, like every other per-project AI flag.
#   Flipping the central switch must not start offering customer-facing
#   generation in every project at once - this text goes to customers.
# - ai_answer_prompt/-_mode combine the project prompt with the central default
#   exactly like ai_prompt/ai_prompt_mode do for summaries (AI_PROMPT_MODES).
class AddAiAnswerSettingsToHelpdeskProjectSettings < ActiveRecord::Migration[6.1]
  def change
    change_table :helpdesk_project_settings, :bulk => true do |t|
      unless column_exists?(:helpdesk_project_settings, :ai_answer_enabled)
        t.boolean :ai_answer_enabled, :default => false, :null => false
      end
      unless column_exists?(:helpdesk_project_settings, :ai_answer_prompt)
        t.text :ai_answer_prompt
      end
      unless column_exists?(:helpdesk_project_settings, :ai_answer_prompt_mode)
        t.string :ai_answer_prompt_mode, :limit => 10, :default => 'inherit'
      end
    end
  end
end
