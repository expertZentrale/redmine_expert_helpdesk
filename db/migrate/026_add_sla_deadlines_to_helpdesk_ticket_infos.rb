# Absolute Faelligkeits-Zeitpunkte je SLA-Uhr (aus den Geschaeftsminuten +
# Arbeitszeit vorberechnet). Ermoeglicht Sortier-/Filterspalten im Ticket-Grid
# per reinem Zeitstempel-Vergleich gegen die aktuelle Zeit (ohne Geschaeftszeit-
# Rechnung zur Abfragezeit). warn_at = Faelligkeit bei 80 % der Zielzeit.
class AddSlaDeadlinesToHelpdeskTicketInfos < ActiveRecord::Migration[6.1]
  def change
    change_table :helpdesk_ticket_infos, :bulk => true do |t|
      t.datetime :sla_reaction_due_at  unless column_exists?(:helpdesk_ticket_infos, :sla_reaction_due_at)
      t.datetime :sla_reaction_warn_at unless column_exists?(:helpdesk_ticket_infos, :sla_reaction_warn_at)
      t.datetime :sla_solution_due_at  unless column_exists?(:helpdesk_ticket_infos, :sla_solution_due_at)
      t.datetime :sla_solution_warn_at unless column_exists?(:helpdesk_ticket_infos, :sla_solution_warn_at)
    end
  end
end
