# Autoritative Ticket-Zuordnung: Kunde und Ursprungspostfach je Ticket.
# Ersetzt die Konvention "Kontakt der ersten HelpdeskMessage = Kunde des Tickets".
# Backfill: bestehende Tickets erhalten Kunde/Postfach aus ihrer ersten Nachricht.
class CreateHelpdeskTicketInfos < ActiveRecord::Migration[6.1]
  def up
    unless table_exists?(:helpdesk_ticket_infos)
      create_table :helpdesk_ticket_infos do |t|
        t.integer :issue_id, :null => false
        t.integer :helpdesk_contact_id
        t.integer :helpdesk_mailbox_id
        t.timestamps
      end
      add_index :helpdesk_ticket_infos, :issue_id, :unique => true
      add_index :helpdesk_ticket_infos, :helpdesk_contact_id
    end

    # Backfill aus der jeweils ersten Nachricht jedes Tickets
    execute <<~SQL
      INSERT INTO helpdesk_ticket_infos (issue_id, helpdesk_contact_id, helpdesk_mailbox_id, created_at, updated_at)
      SELECT hm.issue_id, hm.helpdesk_contact_id, hm.helpdesk_mailbox_id, NOW(), NOW()
      FROM helpdesk_messages hm
      INNER JOIN (
        SELECT issue_id, MIN(id) AS first_id
        FROM helpdesk_messages
        GROUP BY issue_id
      ) f ON f.first_id = hm.id
      WHERE hm.issue_id NOT IN (SELECT issue_id FROM helpdesk_ticket_infos)
    SQL
  end

  def down
    drop_table :helpdesk_ticket_infos if table_exists?(:helpdesk_ticket_infos)
  end
end
