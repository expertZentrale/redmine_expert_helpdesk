# Clears the "awaiting agent" flag as soon as an agent answers the customer.
#
# Hooked on Journal#after_create rather than on controller_issues_edit_after_save so
# that one place covers the web UI, bulk edit, the REST API and scripts. Bulk edit is
# the reason: IssuesController#bulk_update fires controller_issues_bulk_edit_before_save,
# not controller_issues_edit_after_save.
module RedmineExpertHelpdesk
  module Patches
    module JournalPatch
      def self.included(base)
        base.after_create :helpdesk_clear_awaiting_agent
      end

      # A public (non-private) note written by an agent answers the customer.
      #
      # The send_helpdesk_reply check is what excludes the inbound MailHandler journal:
      # the customer is not an agent, so their reply must not clear the flag it just set.
      # A private note is an internal remark, not an answer, and deliberately keeps the
      # ticket flagged.
      def helpdesk_clear_awaiting_agent
        return unless journalized.is_a?(Issue)
        return if notes.blank? || private_notes?
        return unless HelpdeskTicketInfo.awaiting_agent_enabled?

        issue = journalized
        return unless issue.project&.module_enabled?(:helpdesk)
        return unless user.present? && user.allowed_to?(:send_helpdesk_reply, issue.project)

        HelpdeskTicketInfo.clear_awaiting_agent!(issue)
      rescue StandardError => e
        Rails.logger.warn("Helpdesk: clear_awaiting_agent (Journal ##{id}) fehlgeschlagen: #{e.message}")
      end
    end
  end
end
