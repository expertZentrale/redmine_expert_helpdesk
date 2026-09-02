# Minimum size (KB) at which an image counts as a screenshot/photo.
# Signature logos and tracking pixels are attached to nearly every mail and are
# typically 1-10 KB; without this floor "attachment required" would be satisfied
# every single time and the rule would be useless. Images only - a small log or
# PDF is real evidence despite its size.
class AddInfoRequestMinAttachmentToHelpdeskProjectSettings < ActiveRecord::Migration[6.1]
  def change
    return if column_exists?(:helpdesk_project_settings, :info_request_min_attachment_kb)

    add_column :helpdesk_project_settings, :info_request_min_attachment_kb,
               :integer, :default => 15
  end
end
