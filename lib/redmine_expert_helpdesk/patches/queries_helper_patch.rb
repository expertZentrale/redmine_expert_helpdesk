# Rendert die SLA-Grid-Spalten (Reaktion/Loesung) als farbige Ampel-Chips,
# wiederverwendet die hd-sla-*-Styles aus helpdesk_activity.css (auf jeder Seite
# via view_layouts_base_html_head eingebunden). Andere Spalten unveraendert.
module RedmineExpertHelpdesk
  module Patches
    module QueriesHelperPatch
      SLA_COLUMNS = [:helpdesk_sla_reaction, :helpdesk_sla_solution].freeze

      SLA_CSS = {
        :met           => 'hd-sla-met',
        :running       => 'hd-sla-running',
        :warning       => 'hd-sla-warning',
        :breached      => 'hd-sla-breached',
        :breached_done => 'hd-sla-breached'
      }.freeze

      def column_content(column, item)
        return super unless SLA_COLUMNS.include?(column.name) && item.is_a?(Issue)

        status = item.send(column.name)
        return ''.html_safe if status.nil?

        content_tag(:span, l("label_helpdesk_sla_#{status}"),
                    :class => "hd-sla-chip #{SLA_CSS[status]}")
      end
    end
  end
end
