class CreateHelpdeskMessages < ActiveRecord::Migration[6.1]
  def change
    create_table :helpdesk_messages do |t|
      t.references :issue, :null => false, :index => true
      t.references :helpdesk_contact, :index => true
      t.references :helpdesk_mailbox, :index => true
      t.string :direction, :null => false, :default => 'in'
      t.string :message_id
      t.string :subject
      t.datetime :sent_at
      t.timestamps
    end
    add_index :helpdesk_messages, :message_id
  end
end
