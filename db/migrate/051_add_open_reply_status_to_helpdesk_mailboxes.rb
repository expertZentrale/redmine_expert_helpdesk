# Status for a customer reply that lands on an *open* ticket, the counterpart to
# reopen_status_id from migration 012.
#
# One status for both cases was not enough: a helpdesk that leaves tickets open
# while it waits for the customer ("waiting for customer", "on hold") still wants
# the reply to move them on, and that target status is not the one a reopened,
# already closed ticket should land in.
#
# Blank = the status of an open ticket is left alone, which is what every
# installation did before this column existed.
class AddOpenReplyStatusToHelpdeskMailboxes < ActiveRecord::Migration[6.1]
  def change
    add_column :helpdesk_mailboxes, :open_reply_status_id, :integer unless
      column_exists?(:helpdesk_mailboxes, :open_reply_status_id)
  end
end
