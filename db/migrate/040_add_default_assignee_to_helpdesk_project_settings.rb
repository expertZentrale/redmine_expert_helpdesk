# Per-project default assignee for tickets created from incoming mail.
# Holds a Principal id (user *or* group), mirroring issues.assigned_to_id;
# NULL means "do not assign".
class AddDefaultAssigneeToHelpdeskProjectSettings < ActiveRecord::Migration[6.1]
  def change
    add_column :helpdesk_project_settings, :default_assigned_to_id, :integer unless
      column_exists?(:helpdesk_project_settings, :default_assigned_to_id)
  end
end
