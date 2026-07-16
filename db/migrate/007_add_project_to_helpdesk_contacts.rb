class AddProjectToHelpdeskContacts < ActiveRecord::Migration[6.1]
  def up
    # project_id einfuegen (nullable, damit bestehende Daten erhalten bleiben)
    add_column :helpdesk_contacts, :project_id, :integer unless column_exists?(:helpdesk_contacts, :project_id)
    add_column :helpdesk_contacts, :phone,      :string  unless column_exists?(:helpdesk_contacts, :phone)

    # Bestehende Kontakte: project_id aus dem ersten verknuepften Ticket uebernehmen
    execute <<~SQL
      UPDATE helpdesk_contacts hc
      SET    project_id = (
        SELECT i.project_id
        FROM   helpdesk_messages hm
        INNER  JOIN issues i ON i.id = hm.issue_id
        WHERE  hm.helpdesk_contact_id = hc.id
        ORDER  BY hm.id ASC
        LIMIT  1
      )
      WHERE  hc.project_id IS NULL
    SQL

    # Doppelte Kontakte pro (email, project_id) zusammenfuehren:
    # Nachrichten auf den ersten vorhandenen Kontakt umbiegen, Rest loeschen.
    execute <<~SQL
      UPDATE helpdesk_messages hm
      SET    helpdesk_contact_id = (
        SELECT MIN(id) FROM helpdesk_contacts
        WHERE  LOWER(email) = LOWER((SELECT email FROM helpdesk_contacts WHERE id = hm.helpdesk_contact_id))
          AND  project_id   = (SELECT project_id FROM helpdesk_contacts WHERE id = hm.helpdesk_contact_id)
      )
      WHERE  hm.helpdesk_contact_id IS NOT NULL
    SQL

    execute <<~SQL
      DELETE FROM helpdesk_contacts
      WHERE id NOT IN (
        SELECT MIN(id) FROM helpdesk_contacts
        WHERE  project_id IS NOT NULL
        GROUP  BY LOWER(email), project_id
      )
      AND project_id IS NOT NULL
    SQL

    # Alten eindeutigen Index auf email entfernen, neuen zusammengesetzten anlegen
    remove_index  :helpdesk_contacts, :email rescue nil
    add_index     :helpdesk_contacts, [:email, :project_id], :unique => true,
                  :name => 'index_helpdesk_contacts_on_email_and_project'
    add_index     :helpdesk_contacts, :project_id, :name => 'index_helpdesk_contacts_on_project_id'
  end

  def down
    remove_index  :helpdesk_contacts, :name => 'index_helpdesk_contacts_on_email_and_project' rescue nil
    remove_index  :helpdesk_contacts, :name => 'index_helpdesk_contacts_on_project_id'        rescue nil
    remove_column :helpdesk_contacts, :project_id
    remove_column :helpdesk_contacts, :phone
    add_index     :helpdesk_contacts, :email, :unique => true
  end
end
