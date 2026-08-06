# "Awaiting agent" flag: a customer replied by mail and nobody has answered yet.
# awaiting_agent_since is the timestamp of the OLDEST unanswered customer reply,
# so NULL/NOT NULL acts as the flag while the value doubles as the sort key
# ("waiting since") for the ticket grid. awaiting_agent_reason tells apart a plain
# reply from an auto-reopened ticket.
class AddAwaitingAgentToHelpdeskTicketInfos < ActiveRecord::Migration[6.1]
  def change
    change_table :helpdesk_ticket_infos, :bulk => true do |t|
      t.datetime :awaiting_agent_since unless column_exists?(:helpdesk_ticket_infos, :awaiting_agent_since)
      t.string :awaiting_agent_reason, :limit => 20 unless column_exists?(:helpdesk_ticket_infos, :awaiting_agent_reason)
    end

    unless index_exists?(:helpdesk_ticket_infos, :awaiting_agent_since)
      add_index :helpdesk_ticket_infos, :awaiting_agent_since
    end
  end
end
