# Sichtbarkeit der Journal-Notiz, die eine automatische Rueckfrage protokolliert:
# public  = Bearbeiter UND Kunde sehen, was erfragt wurde
# private = interne Notiz, nur fuer Bearbeiter mit view_private_notes
# Default 'public', weil die Notiz genau das dokumentiert, was der Kunde ohnehin
# per Mail bekommen hat.
class AddInfoRequestNoteVisibilityToHelpdeskProjectSettings < ActiveRecord::Migration[6.1]
  def change
    return if column_exists?(:helpdesk_project_settings, :info_request_note_visibility)

    add_column :helpdesk_project_settings, :info_request_note_visibility,
               :string, :limit => 10, :default => 'public', :null => false
  end
end
