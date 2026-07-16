# SLA-Zielzeiten je Prioritaet (Override der Projekt-Defaults).
# Leere Werte bedeuten: Projekt-Default gilt.
class CreateHelpdeskSlaPriorities < ActiveRecord::Migration[6.1]
  def change
    unless table_exists?(:helpdesk_sla_priorities)
      create_table :helpdesk_sla_priorities do |t|
        t.integer :project_id,  :null => false
        t.integer :priority_id, :null => false
        t.integer :reaction_minutes
        t.integer :solution_minutes
      end
      add_index :helpdesk_sla_priorities, [:project_id, :priority_id], :unique => true,
                :name => 'index_hd_sla_priorities_on_project_and_priority'
    end
  end
end
