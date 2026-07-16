class AddSentAttachmentsToHelpdeskMessages < ActiveRecord::Migration[6.1]
  def change
    add_column :helpdesk_messages, :sent_attachments, :text unless column_exists?(:helpdesk_messages, :sent_attachments)
  end
end
