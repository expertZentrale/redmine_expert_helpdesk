# Ticket infos of a whole page of issues in one query instead of one per row
# and column: the awaiting highlight (css_classes), the customer and SLA columns
# all read it. IssueQuery#issues only attaches a deferred batch
# (IssuePatch.defer_ticket_infos); the first row that reads the data loads it for
# the page, and callers that never read it (the REST API) pay nothing. Covers the
# issue list, the My page issue blocks, Gantt, calendar and exports.
#
# Applied via UnboundMethod capture, NOT prepend/super: RedmineUP
# redmine_contacts_helpdesk wraps IssueQuery#issues with alias_method, and an
# alias taken after our prepend captures the prepended method, whose super then
# lands on the alias again - endless recursion. Same reason and pattern as
# IssueCssClassesPatch; capture is order-insensitive.
module RedmineExpertHelpdesk
  module Patches
    module IssueQueryPreloadPatch
      # Columns that need each row's customer contact.
      CONTACT_COLUMNS = [:helpdesk_kunde, :helpdesk_kunde_email].freeze

      def self.apply!(base)
        return if base.instance_variable_get(:@expert_helpdesk_issues_preload_patched)

        original = base.instance_method(:issues)
        base.send(:define_method, :issues) do |*args|
          issues = original.bind(self).call(*args)
          begin
            contacts = columns.any? { |c| CONTACT_COLUMNS.include?(c.name) }
            RedmineExpertHelpdesk::Patches::IssuePatch.defer_ticket_infos(issues, contacts)
          rescue StandardError => e
            # The rows then look their data up one by one, as before.
            Rails.logger.warn "Helpdesk: ticket info preload failed: #{e.message}"
          end
          issues
        end

        base.instance_variable_set(:@expert_helpdesk_issues_preload_patched, true)
      end
    end
  end
end
