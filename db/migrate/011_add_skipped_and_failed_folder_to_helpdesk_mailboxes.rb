class AddSkippedAndFailedFolderToHelpdeskMailboxes < ActiveRecord::Migration[6.1]
  def change
    # Zielordner fuer uebersprungene Mails (Blacklist, Ignorier-Regeln, Auto-Reply-Filter)
    add_column :helpdesk_mailboxes, :skipped_folder, :string unless column_exists?(:helpdesk_mailboxes, :skipped_folder)
    # Zielordner fuer Mails, bei deren Verarbeitung ein Fehler aufgetreten ist
    add_column :helpdesk_mailboxes, :failed_folder, :string unless column_exists?(:helpdesk_mailboxes, :failed_folder)
  end
end
