# Direkte Verknuepfung eingehender Nachrichten mit dem zugehoerigen Journal.
# Ersetzt das Timestamp-Matching im Frontend fuer eingehende Mails
# (MailHandler liefert das Journal-Objekt direkt, die ID kann gespeichert werden).
class AddJournalIdToHelpdeskMessages < ActiveRecord::Migration[6.1]
  def change
    unless column_exists?(:helpdesk_messages, :journal_id)
      add_column :helpdesk_messages, :journal_id, :integer
      add_index :helpdesk_messages, :journal_id
    end
  end
end
