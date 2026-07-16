class AddEmlAttachmentIdToHelpdeskMessages < ActiveRecord::Migration[6.1]
  def change
    add_column :helpdesk_messages, :eml_attachment_id, :integer
    add_index  :helpdesk_messages, :eml_attachment_id
  end
end
