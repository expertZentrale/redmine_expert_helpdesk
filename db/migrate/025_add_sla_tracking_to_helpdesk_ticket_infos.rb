# SLA-Tracking je Ticket: Zeitpunkt der ersten Reaktion, berechnete
# Geschaeftsminuten und Benachrichtigungs-Marker (gegen Doppel-Mails).
class AddSlaTrackingToHelpdeskTicketInfos < ActiveRecord::Migration[6.1]
  def change
    change_table :helpdesk_ticket_infos, :bulk => true do |t|
      t.datetime :first_response_at unless column_exists?(:helpdesk_ticket_infos, :first_response_at)
      t.integer  :reaction_business_minutes unless column_exists?(:helpdesk_ticket_infos, :reaction_business_minutes)
      t.integer  :solution_business_minutes unless column_exists?(:helpdesk_ticket_infos, :solution_business_minutes)
      t.datetime :sla_reaction_notified_at unless column_exists?(:helpdesk_ticket_infos, :sla_reaction_notified_at)
      t.datetime :sla_solution_notified_at unless column_exists?(:helpdesk_ticket_infos, :sla_solution_notified_at)
    end
  end
end
