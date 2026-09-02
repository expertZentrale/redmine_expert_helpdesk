# Optional From override for mailboxes that send through Redmine's own SMTP
# configuration (reply_transport 'smtp'). NULL/blank means "use the mailbox
# address", which is the behaviour every existing mailbox had.
#
# Only relevant for the 'smtp' route: Graph and the mailbox's own SMTP server
# authenticate as the mailbox itself and reject a foreign sender, so the
# override is deliberately ignored there.
class AddSmtpFromAddressToHelpdeskMailboxes < ActiveRecord::Migration[6.1]
  def change
    add_column :helpdesk_mailboxes, :smtp_from_address, :string unless
      column_exists?(:helpdesk_mailboxes, :smtp_from_address)
  end
end
