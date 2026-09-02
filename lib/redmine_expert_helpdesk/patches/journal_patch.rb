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
      #
      # Anonymous is excluded on top of that permission check, because the plugin's own
      # automatic notes (autoresponder, phishing warning, completeness follow-up) are all
      # authored by User.anonymous and are the plugin talking, not an agent answering.
      # The permission check alone is not enough: a project that grants
      # send_helpdesk_reply to the Anonymous role would let the phishing note clear the
      # very flag mark_awaiting_agent! had just set a few lines earlier. A real agent
      # reply is never anonymous - the reply controller and the web UI both run as a
      # logged-in user.
      def helpdesk_clear_awaiting_agent
        return unless journalized.is_a?(Issue)
        return if notes.blank? || private_notes?
        return if user.nil? || user.anonymous?
        return unless HelpdeskTicketInfo.awaiting_agent_enabled?

        issue = journalized
        return unless issue.project&.module_enabled?(:helpdesk)
        return unless user.allowed_to?(:send_helpdesk_reply, issue.project)

        HelpdeskTicketInfo.clear_awaiting_agent!(issue)
      rescue StandardError => e
        Rails.logger.warn("Helpdesk: clear_awaiting_agent (Journal ##{id}) fehlgeschlagen: #{e.message}")
      end
    end
  end
end
