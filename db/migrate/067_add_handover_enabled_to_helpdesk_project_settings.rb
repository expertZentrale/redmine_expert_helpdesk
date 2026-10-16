# Per-project switch for the experimental hand-over to other projects
# (RedmineExpertHelpdesk::Handover). Off by default; the central setting
# handover_enabled has to be on as well.
class AddHandoverEnabledToHelpdeskProjectSettings < ActiveRecord::Migration[6.1]
  # Explicit up/down, like 065: with a column_exists? guard a reversible
  # `change` records nothing to invert, so a rollback left the column behind.
  def up
    return if column_exists?(:helpdesk_project_settings, :handover_enabled)

    add_column :helpdesk_project_settings, :handover_enabled, :boolean, :default => false, :null => false
  end

  def down
    return unless column_exists?(:helpdesk_project_settings, :handover_enabled)

    remove_column :helpdesk_project_settings, :handover_enabled
  end
end
