# Loads the ticket info of a whole page of issues in one query
# (IssuePatch.preload_ticket_infos): every row of the grid reads it - the
# awaiting highlight via css_classes, the customer and SLA columns - which was one
# query per row and column. Covers the issue list, the My page blocks and exports,
# all of which go through IssueQuery#issues.
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
            # Only when something on the page reads it: the awaiting highlight
            # (css_classes) or one of our columns. Gantt, calendar and the REST
            # API call #issues too and need neither.
            names = columns.map(&:name)
            if HelpdeskTicketInfo.awaiting_agent_enabled? || names.any? { |n| n.to_s.start_with?('helpdesk_') }
              contacts = names.any? { |n| CONTACT_COLUMNS.include?(n) }
              RedmineExpertHelpdesk::Patches::IssuePatch.preload_ticket_infos(issues, contacts)
            end
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
