# Audit trail and repeat guard for the automatic request for more information.
# info_request_count stays the authoritative guard (a re-fetch, a reopen or a
# manual re-run must never mail the customer twice); info_request_sent_at is the
# timestamp shown to agents.
class AddInfoRequestToHelpdeskTicketInfos < ActiveRecord::Migration[6.1]
  def change
    change_table :helpdesk_ticket_infos, :bulk => true do |t|
      unless column_exists?(:helpdesk_ticket_infos, :info_request_sent_at)
        t.datetime :info_request_sent_at
      end
      unless column_exists?(:helpdesk_ticket_infos, :info_request_count)
        t.integer :info_request_count, :default => 0, :null => false
      end
    end
  end
end
