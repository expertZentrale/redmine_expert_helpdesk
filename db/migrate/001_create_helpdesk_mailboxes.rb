class CreateHelpdeskMailboxes < ActiveRecord::Migration[6.1]
  def change
    create_table :helpdesk_mailboxes do |t|
      t.references :project, :null => false, :index => true
      t.string  :mailbox_address, :null => false
      t.string  :source_folder, :default => 'Inbox'
      t.string  :processed_folder, :default => 'Verarbeitet'
      t.boolean :enabled, :default => true, :null => false
      t.integer :default_tracker_id
      t.integer :default_priority_id
      t.integer :default_status_id
      t.string  :unknown_user_mode, :default => 'accept'
      t.boolean :suppress_notifications, :default => false, :null => false
      t.text    :allow_list
      t.text    :deny_list
      t.boolean :autoresponder_enabled, :default => false, :null => false
      t.string  :autoresponder_subject
      t.text    :autoresponder_body
      t.text    :reply_header
      t.text    :reply_footer
      t.datetime :last_fetched_at
      t.timestamps
    end
    add_index :helpdesk_mailboxes, :mailbox_address, :unique => true
  end
end
