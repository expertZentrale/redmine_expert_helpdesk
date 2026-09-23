# Per-project colours of the customer-facing block in the ticket edit form.
#
# NULL/blank inherits the central plugin setting, which in turn falls back to the
# constants in RedmineExpertHelpdesk::ReplyBox. Seven characters is a "#rrggbb"; the
# model rejects anything that is not a hex colour, because these values end up in a
# stylesheet.
class AddReplyBoxColorsToHelpdeskProjectSettings < ActiveRecord::Migration[6.1]
  def change
    unless column_exists?(:helpdesk_project_settings, :reply_box_color)
      add_column :helpdesk_project_settings, :reply_box_color, :string, :limit => 7
    end

    unless column_exists?(:helpdesk_project_settings, :reply_hazard_color)
      add_column :helpdesk_project_settings, :reply_hazard_color, :string, :limit => 7
    end
  end
end
