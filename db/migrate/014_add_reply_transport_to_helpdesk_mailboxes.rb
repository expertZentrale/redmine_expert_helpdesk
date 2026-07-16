class AddReplyTransportToHelpdeskMailboxes < ActiveRecord::Migration[6.1]
  def change
    add_column :helpdesk_mailboxes, :reply_transport, :string, :default => 'graph' unless column_exists?(:helpdesk_mailboxes, :reply_transport)
  end
end
