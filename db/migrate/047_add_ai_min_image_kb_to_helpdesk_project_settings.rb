# Minimum size (KB) an image must have to be sent to the AI (vision) model.
# Signature logos, social icons and tracking pixels hang off nearly every mail and
# are typically 1-10 KB; sending them costs vision tokens for nothing and pushes
# the real screenshot out of the small per-request image budget. 0 disables the
# floor. Applies to images only - attachment text/metadata are unaffected.
class AddAiMinImageKbToHelpdeskProjectSettings < ActiveRecord::Migration[6.1]
  def change
    return if column_exists?(:helpdesk_project_settings, :ai_min_image_kb)

    add_column :helpdesk_project_settings, :ai_min_image_kb, :integer, :default => 15
  end
end
