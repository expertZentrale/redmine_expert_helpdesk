# The mailbox a ticket was handed over to (RedmineExpertHelpdesk::Handover).
# A handed-over ticket has no incoming mail, so this is what tells
# ThreadScope it belongs to that mailbox's project after a move. Written by
# Handover only - helpdesk_mailbox_id is also filled by replies and proves
# nothing.
class AddHandoverMailboxIdToHelpdeskTicketInfos < ActiveRecord::Migration[6.1]
  def up
    return if column_exists?(:helpdesk_ticket_infos, :handover_mailbox_id)

    add_column :helpdesk_ticket_infos, :handover_mailbox_id, :integer
  end

  def down
    return unless column_exists?(:helpdesk_ticket_infos, :handover_mailbox_id)

    remove_column :helpdesk_ticket_infos, :handover_mailbox_id
  end
end
