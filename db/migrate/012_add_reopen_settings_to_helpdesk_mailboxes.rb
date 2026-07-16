class AddReopenSettingsToHelpdeskMailboxes < ActiveRecord::Migration[6.1]
  def change
    # Status, auf den ein geschlossenes Ticket beim Eingang einer neuen Antwort gesetzt wird
    add_column :helpdesk_mailboxes, :reopen_status_id, :integer unless column_exists?(:helpdesk_mailboxes, :reopen_status_id)
    # Maximales Alter (Tage seit letzter Aktualisierung) fuer die Wiedereroeffnung.
    # Ist das Ticket aelter, wird stattdessen ein neues Ticket angelegt.
    # Leer / 0 = kein Alterslimit (immer wiedereroefffnen, sofern Status konfiguriert).
    add_column :helpdesk_mailboxes, :reopen_max_age_days, :integer unless column_exists?(:helpdesk_mailboxes, :reopen_max_age_days)
  end
end
