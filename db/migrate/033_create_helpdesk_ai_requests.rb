# Einheitliches Nutzungs-Protokoll fuer JEDEN KI-Aufruf (Zusammenfassung,
# Wissensbasis-Extraktion, Embedding, RAG-Retrieval). Grundlage der KI-Statistik:
# erfasst Provider/Modell, Token, Dauer und Erfolg/Fehler pro Anfrage – inkl.
# Fehlversuchen (die sonst nur geloggt werden) und mit direkter Projektzuordnung.
class CreateHelpdeskAiRequests < ActiveRecord::Migration[6.1]
  def change
    return if table_exists?(:helpdesk_ai_requests)

    create_table :helpdesk_ai_requests do |t|
      t.string   :request_type, :null => false   # summary | kb_extract | kb_embed | kb_retrieve
      t.string   :provider
      t.string   :model
      t.integer  :project_id                      # aus dem Job-Kontext, i. d. R. gesetzt
      t.integer  :issue_id
      t.integer  :input_tokens
      t.integer  :output_tokens
      t.integer  :duration_ms
      t.boolean  :success, :null => false, :default => true
      t.string   :error_class                     # nil bei Erfolg
      t.integer  :http_status                     # aus AiError#status bei Fehler
      t.datetime :created_at, :null => false
    end
    add_index :helpdesk_ai_requests, [:project_id, :created_at]
    add_index :helpdesk_ai_requests, [:request_type, :created_at]
    add_index :helpdesk_ai_requests, :issue_id
  end
end
