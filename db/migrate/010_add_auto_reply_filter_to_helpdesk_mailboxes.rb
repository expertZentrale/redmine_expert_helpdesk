class AddAutoReplyFilterToHelpdeskMailboxes < ActiveRecord::Migration[6.1]
  def change
    # Filterung automatisch generierter Nachrichten (Auto-Reply, Abwesenheit usw.)
    add_column :helpdesk_mailboxes, :auto_reply_filter_enabled,   :boolean, :default => false, :null => false unless column_exists?(:helpdesk_mailboxes, :auto_reply_filter_enabled)
    # Absender-Whitelist: Adressen/Domains, deren Auto-Replies trotzdem verarbeitet werden
    add_column :helpdesk_mailboxes, :auto_reply_sender_whitelist, :text unless column_exists?(:helpdesk_mailboxes, :auto_reply_sender_whitelist)
    # Header-Whitelist: "Header: Wert"-Eintraege, die den Auto-Reply-Filter deaktivieren
    add_column :helpdesk_mailboxes, :auto_reply_header_whitelist, :text unless column_exists?(:helpdesk_mailboxes, :auto_reply_header_whitelist)
  end
end
