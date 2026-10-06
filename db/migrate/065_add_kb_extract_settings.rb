# Detail level of knowledge-base extraction, per project, plus the project's
# own extraction prompt combined like the other AI prompts (AI_PROMPT_MODES).
# - helpdesk_project_settings.kb_extract_detail: general / specific /
#   most_specific; NULL takes the central level.
# - helpdesk_knowledge_entries.extract_detail: the level an entry was extracted
#   at, so re-extraction can find the entries a level change left behind. NULL
#   means extracted before levels existed, i.e. 'general'.
class AddKbExtractSettings < ActiveRecord::Migration[6.1]
  # Explicit up/down: with column_exists? guards a reversible `change` records
  # no inverse operations, so a downgrade would leave the columns behind.
  SETTING_COLUMNS = {
    :kb_extract_detail      => [:string, { :limit => 20 }],
    :kb_extract_prompt      => [:text, {}],
    :kb_extract_prompt_mode => [:string, { :limit => 10, :default => 'inherit' }]
  }.freeze

  def up
    SETTING_COLUMNS.each do |name, (type, opts)|
      add_column :helpdesk_project_settings, name, type, **opts unless column_exists?(:helpdesk_project_settings, name)
    end
    return if column_exists?(:helpdesk_knowledge_entries, :extract_detail)

    add_column :helpdesk_knowledge_entries, :extract_detail, :string, :limit => 20
  end

  def down
    SETTING_COLUMNS.each_key do |name|
      remove_column :helpdesk_project_settings, name if column_exists?(:helpdesk_project_settings, name)
    end
    return unless column_exists?(:helpdesk_knowledge_entries, :extract_detail)

    remove_column :helpdesk_knowledge_entries, :extract_detail
  end
end
