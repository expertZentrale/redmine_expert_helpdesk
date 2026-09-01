# Extends Issue with:
# - helpdesk_kunde / helpdesk_kunde_email: the ticket's customer contact
#   (display name resp. email only); grid columns "Kunde" / "Kunden-E-Mail"
# - helpdesk_sla_reaction / helpdesk_sla_solution: SLA status per clock, from
#   the precomputed deadlines; grid columns/filters "SLA reaction/solution"
# - after_save: keeps the precomputed SLA deadlines current
module RedmineExpertHelpdesk
  module Patches
    module IssuePatch
      def self.included(base)
        base.after_save :helpdesk_refresh_sla_deadlines
        base.after_save :helpdesk_enqueue_kb_ingest
        base.after_save :helpdesk_clear_awaiting_on_close
      end

      # The ticket's customer contact: the authoritative HelpdeskTicketInfo link
      # first (set on mail ingest, manual init assignment and legacy import),
      # falling back to the sender of the first incoming mail for legacy tickets
      # without a ticket-info row. nil when the ticket has no customer (e.g.
      # agent-created without an assigned contact) -- that is expected.
      # Wrapped in an array so a nil result is memoized too; both customer grid
      # columns hit this once per row (mirrors helpdesk_awaiting_agent).
      def helpdesk_customer_contact
        @helpdesk_customer_contact ||= begin
          contact = HelpdeskTicketInfo.for_issue(self)&.helpdesk_contact
          contact ||= HelpdeskMessage
                        .joins(:helpdesk_contact)
                        .where(:issue_id => id, :direction => 'in')
                        .order(:id => :asc)
                        .first&.helpdesk_contact
          [contact]
        end
        @helpdesk_customer_contact.first
      end

      # Display name of the customer contact (grid column "Kunde"), or nil.
      def helpdesk_kunde
        helpdesk_customer_contact&.display_name
      end

      # Email address of the customer contact (grid column "Kunden-E-Mail"), or
      # nil. Separate column because display names can be long and unclear.
      def helpdesk_kunde_email
        helpdesk_customer_contact&.email
      end

      # SLA-Status der Reaktionsuhr (nil, wenn kein SLA greift). Ohne erfasste
      # Erstreaktion gilt bei geschlossenen Tickets der Schliesszeitpunkt als
      # Abschluss (Reaktion laeuft nicht ueber das Loesen hinaus weiter).
      def helpdesk_sla_reaction
        info = HelpdeskTicketInfo.for_issue(self)
        return nil unless info

        done = info.first_response_at || (closed? ? closed_on : nil)
        RedmineExpertHelpdesk::Sla.clock_status_from(
          info.sla_reaction_due_at, info.sla_reaction_warn_at, done)
      end

      # SLA-Status der Loesungsuhr (nil, wenn kein SLA greift).
      def helpdesk_sla_solution
        info = HelpdeskTicketInfo.for_issue(self)
        return nil unless info

        done = closed? ? closed_on : nil
        RedmineExpertHelpdesk::Sla.clock_status_from(
          info.sla_solution_due_at, info.sla_solution_warn_at, done)
      end

      # [since, reason] when a customer is waiting for an answer, otherwise nil.
      # Wrapped in an array so a nil result is memoized too -- this is hit once per
      # grid row by both column_content and css_classes.
      def helpdesk_awaiting_agent
        @helpdesk_awaiting_agent ||= begin
          info = HelpdeskTicketInfo.awaiting_agent_enabled? ? HelpdeskTicketInfo.for_issue(self) : nil
          [info&.awaiting_agent_since ? [info.awaiting_agent_since, info.awaiting_agent_reason] : nil]
        end
        @helpdesk_awaiting_agent.first
      end

      # Closing a ticket answers the customer even without a note. At the model
      # (after_save) so bulk and API changes are caught too -- same reasoning as the
      # KB ingest below.
      def helpdesk_clear_awaiting_on_close
        return unless saved_change_to_status_id? && closed?
        return unless project&.module_enabled?(:helpdesk)

        HelpdeskTicketInfo.clear_awaiting_agent!(self)
      rescue StandardError => e
        Rails.logger.warn("Helpdesk: clear_awaiting_on_close fehlgeschlagen (Issue ##{id}): #{e.message}")
      end

      # Nach dem Speichern die vorberechneten Faelligkeiten aktualisieren, aber
      # nur wenn relevant (neu, Prioritaet geaendert oder noch nicht berechnet),
      # um die Geschaeftszeit-Schleife nicht bei jedem Speichern zu durchlaufen.
      def helpdesk_refresh_sla_deadlines
        return unless project&.module_enabled?(:helpdesk)

        relevant = saved_change_to_id? || saved_change_to_priority_id? ||
                   HelpdeskTicketInfo.for_issue(self)&.sla_reaction_due_at.nil?
        return unless relevant

        RedmineExpertHelpdesk::Sla.refresh_deadlines!(self)
      end

      # Beim Schliessen das geloeste Ticket in die Wissensbasis aufnehmen (async).
      # Am Modell (after_save), damit auch Sammel-Aenderungen (Bulk-Update) und
      # API-/Skript-Aenderungen erfasst werden, nicht nur Einzel-Updates ueber den
      # Controller. Fehler duerfen das Speichern nicht abbrechen.
      def helpdesk_enqueue_kb_ingest
        return unless saved_change_to_status_id? && closed?
        return unless project&.module_enabled?(:helpdesk)
        return unless RedmineExpertHelpdesk::AiFeatures.kb_enabled?

        ps = HelpdeskProjectSetting.for_project(project)
        return if ps.kb_ingest_mode.to_s == 'off'

        HelpdeskKnowledgeIngestJob.perform_later(id)
      rescue StandardError => e
        Rails.logger.warn("Helpdesk: KB-Enqueue (after_save) fehlgeschlagen (Issue ##{id}): #{e.message}")
      end
    end
  end
end
