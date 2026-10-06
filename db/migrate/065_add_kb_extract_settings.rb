# Detail level of knowledge-base extraction, per project, plus the project's
# own extraction prompt combined like the other AI prompts (AI_PROMPT_MODES).
# - helpdesk_project_settings.kb_extract_detail: general / specific /
#   most_specific; NULL takes the central level.
# - helpdesk_knowledge_entries.extract_detail: the level an entry was extracted
#   at, so re-extraction can find the entries a level change left behind. NULL
#   means extracted before levels existed, i.e. 'general'.
class AddKbExtractSettings < ActiveRecord::Migration[6.1]
  def change
    change_table :helpdesk_project_settings, :bulk => true do |t|
      t.string :kb_extract_detail, :limit => 20 unless column_exists?(:helpdesk_project_settings, :kb_extract_detail)
      t.text :kb_extract_prompt unless column_exists?(:helpdesk_project_settings, :kb_extract_prompt)
      unless column_exists?(:helpdesk_project_settings, :kb_extract_prompt_mode)
        t.string :kb_extract_prompt_mode, :limit => 10, :default => 'inherit'
      end
    end
    unless column_exists?(:helpdesk_knowledge_entries, :extract_detail)
      add_column :helpdesk_knowledge_entries, :extract_detail, :string, :limit => 20
    end
  end
end
