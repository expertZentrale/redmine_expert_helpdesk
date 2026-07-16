class AddLastErrorToHelpdeskMailboxes < ActiveRecord::Migration[6.1]
  def change
    add_column :helpdesk_mailboxes, :last_error,    :text
    add_column :helpdesk_mailboxes, :last_error_at, :datetime
  end
end
