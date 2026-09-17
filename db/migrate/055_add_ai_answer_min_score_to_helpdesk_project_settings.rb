# Per-project match threshold for the AI answer draft.
#
# The knowledge base differs wildly between projects: one with 75 curated
# entries can trust a 0.65 match, one with a handful cannot. Blank inherits the
# central ai_answer_min_score, so a project only carries a value when it
# deliberately departs from the default.
#
# Deliberately separate from kb_min_score: that one governs the proposals shown
# to agents inside a summary, this one governs text proposed to a customer.
class AddAiAnswerMinScoreToHelpdeskProjectSettings < ActiveRecord::Migration[6.1]
  def change
    return if column_exists?(:helpdesk_project_settings, :ai_answer_min_score)

    add_column :helpdesk_project_settings, :ai_answer_min_score, :decimal,
               :precision => 4, :scale => 3
  end
end
