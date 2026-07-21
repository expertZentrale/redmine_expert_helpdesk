# Weitere pro-Projekt-Optionen fuer die KI-Zusammenfassung:
#  - ai_include_journal:        kompletten Ticketverlauf (Beschreibung + Notizen)
#                               statt nur der ausloesenden Mail an die KI geben
#  - ai_include_private_notes:  dabei auch private Notizen einbeziehen (nur wirksam,
#                               wenn ai_include_journal aktiv ist)
class AddAiJournalOptionsToHelpdeskProjectSettings < ActiveRecord::Migration[6.1]
  def change
    change_table :helpdesk_project_settings, :bulk => true do |t|
      t.boolean :ai_include_journal,       :default => false, :null => false unless column_exists?(:helpdesk_project_settings, :ai_include_journal)
      t.boolean :ai_include_private_notes, :default => false, :null => false unless column_exists?(:helpdesk_project_settings, :ai_include_private_notes)
    end
  end
end
