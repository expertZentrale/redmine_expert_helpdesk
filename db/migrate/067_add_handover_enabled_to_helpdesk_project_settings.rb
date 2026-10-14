# Per-project switch for the experimental hand-over to other projects
# (RedmineExpertHelpdesk::Handover). Off by default; the central setting
# handover_enabled has to be on as well.
class AddHandoverEnabledToHelpdeskProjectSettings < ActiveRecord::Migration[6.1]
  def change
    return if column_exists?(:helpdesk_project_settings, :handover_enabled)

    add_column :helpdesk_project_settings, :handover_enabled, :boolean, :default => false, :null => false
  end
end
