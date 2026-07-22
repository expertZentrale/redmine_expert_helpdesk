# Loesungsvorschlaege je Ticket, ermittelt bei der Zusammenfassung aus aehnlichen
# geloesten Tickets (RAG). Wird bei jedem Zusammenfassungslauf fuer das Ticket neu
# erzeugt (delete + insert) und in der Ticket-Seitenleiste angezeigt.
class CreateHelpdeskKbProposals < ActiveRecord::Migration[6.1]
  def change
    return if table_exists?(:helpdesk_kb_proposals)

    create_table :helpdesk_kb_proposals do |t|
      t.integer :issue_id,        :null => false
      t.integer :source_issue_id
      t.float   :score
      t.text    :problem
      t.text    :solution
      t.timestamps
    end
    add_index :helpdesk_kb_proposals, :issue_id
  end
end
