# Folder an IMAP mailbox files its outgoing mail in.
#
# Graph's sendMail saves a copy to Sent Items on its own; a plain SMTP server
# does not, so a shared IMAP helpdesk mailbox would show only the inbound half
# of every conversation. Blank means "detect it" - the client prefers the
# RFC 6154 \Sent special-use flag and only falls back to this value.
class AddSentFolderToHelpdeskMailboxes < ActiveRecord::Migration[6.1]
  def change
    t = :helpdesk_mailboxes

    add_column t, :sent_folder, :string unless column_exists?(t, :sent_folder)
  end
end
