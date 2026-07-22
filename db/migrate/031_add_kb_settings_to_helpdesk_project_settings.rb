# Pro-Projekt-Steuerung der Wissensbasis (RAG):
#  - kb_ingest_mode:      off | auto | manual  (traegt dieses Projekt geloeste
#                         Tickets zur Wissensbasis bei, und wie?)
#  - kb_proposal_display: off | summary | sidebar | both  (nutzt dieses Projekt
#                         die Wissensbasis fuer Loesungsvorschlaege, und wo?)
class AddKbSettingsToHelpdeskProjectSettings < ActiveRecord::Migration[6.1]
  def change
    change_table :helpdesk_project_settings, :bulk => true do |t|
      t.string :kb_ingest_mode,      :limit => 10, :default => 'off', :null => false unless column_exists?(:helpdesk_project_settings, :kb_ingest_mode)
      t.string :kb_proposal_display, :limit => 10, :default => 'off', :null => false unless column_exists?(:helpdesk_project_settings, :kb_proposal_display)
    end
  end
end
