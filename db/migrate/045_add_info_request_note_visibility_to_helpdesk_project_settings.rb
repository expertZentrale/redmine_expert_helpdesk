# Visibility of the journal note that records an automatic follow-up:
# public  = agent AND customer see what was asked for
# private = internal note, agents with view_private_notes only
# Default 'public', because the note documents exactly what the customer received
# by mail anyway.
class AddInfoRequestNoteVisibilityToHelpdeskProjectSettings < ActiveRecord::Migration[6.1]
  def change
    return if column_exists?(:helpdesk_project_settings, :info_request_note_visibility)

    add_column :helpdesk_project_settings, :info_request_note_visibility,
               :string, :limit => 10, :default => 'public', :null => false
  end
end
