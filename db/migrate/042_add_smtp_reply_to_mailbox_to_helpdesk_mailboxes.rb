# Opt-in Reply-To for mailboxes using the From override (see migration 041).
#
# Off by default, because the common case is a distribution list that was
# turned into a helpdesk mailbox: the list address still exists and the
# mailbox is its only member, so mail sent under the list address comes back
# to the mailbox on its own and a Reply-To would only expose the internal
# address. Switch it on where the override address does *not* deliver back.
class AddSmtpReplyToMailboxToHelpdeskMailboxes < ActiveRecord::Migration[6.1]
  def change
    add_column :helpdesk_mailboxes, :smtp_reply_to_mailbox, :boolean, :default => false unless
      column_exists?(:helpdesk_mailboxes, :smtp_reply_to_mailbox)
  end
end
