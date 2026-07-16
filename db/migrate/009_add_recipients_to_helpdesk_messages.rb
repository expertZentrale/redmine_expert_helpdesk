class AddRecipientsToHelpdeskMessages < ActiveRecord::Migration[6.1]
  def change
    add_column :helpdesk_messages, :recipient_to,  :text unless column_exists?(:helpdesk_messages, :recipient_to)
    add_column :helpdesk_messages, :recipient_cc,  :text unless column_exists?(:helpdesk_messages, :recipient_cc)
    add_column :helpdesk_messages, :recipient_bcc, :text unless column_exists?(:helpdesk_messages, :recipient_bcc)
  end
end
