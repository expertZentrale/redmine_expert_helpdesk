class AddReplyActionsToHelpdeskProjectSettings < ActiveRecord::Migration[6.1]
  def change
    add_column :helpdesk_project_settings, :reply_status_id,        :integer unless column_exists?(:helpdesk_project_settings, :reply_status_id)
    add_column :helpdesk_project_settings, :reply_assign_to_sender, :boolean, :default => false unless column_exists?(:helpdesk_project_settings, :reply_assign_to_sender)
  end
end
