# Wissensbasis-Eintrag je geloestem Ticket: das extrahierte {Problem, Loesung}
# als System of Record (Dedup, Kuratierung, Re-Embed-Quelle). Die Vektoren
# selbst liegen im externen Vektor-Store (Qdrant/pgvector); hier nur Metadaten
# + Status (pending/approved/skipped) + Referenz auf den Vektor-Punkt.
class CreateHelpdeskKnowledgeEntries < ActiveRecord::Migration[6.1]
  def change
    return if table_exists?(:helpdesk_knowledge_entries)

    create_table :helpdesk_knowledge_entries do |t|
      t.integer :project_id, :null => false
      t.integer :issue_id,   :null => false
      t.text    :problem
      t.text    :solution
      t.string  :status, :limit => 10, :default => 'pending', :null => false
      t.string  :embed_model
      t.string  :point_id
      t.integer :input_tokens
      t.integer :output_tokens
      t.timestamps
    end
    add_index :helpdesk_knowledge_entries, :project_id
    add_index :helpdesk_knowledge_entries, :issue_id, :unique => true
  end
end
