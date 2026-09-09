# Ticket statistics of a project (tab "Ticket statistics"): how the team works
# its helpdesk tickets, independent of SLA. Guarded by the member permission
# view_helpdesk_ticket_statistics (before_action :authorize); the project menu
# hides the tab through the same permission.
class HelpdeskTicketStatisticsController < ApplicationController
  include HelpdeskStatsDateRange
  # hd_stats_minutes / hd_stats_weekday_name live in the SLA helper; Redmine does
  # not include all helpers, so pull it in explicitly.
  helper :helpdesk_sla_statistics

  before_action :find_project_by_project_id
  before_action :authorize

  # Time basis of all durations; 'business' is only offered with SLA enabled.
  BASES = %w[wall business].freeze

  def index
    @period = RedmineExpertHelpdesk::StatisticsSupport.normalize_period(params[:period])
    @range  = resolve_range
    @date_to, @date_from = range_dates(@range)

    @sla_enabled = HelpdeskProjectSetting.for_project(@project).sla_enabled?
    @basis = @sla_enabled && params[:basis] == 'business' ? 'business' : 'wall'

    @stats = RedmineExpertHelpdesk::TicketStatistics.new(
      @project, :period => @period, :date_from => @date_from, :date_to => @date_to,
      :business_hours => @basis == 'business').to_h
  end
end
