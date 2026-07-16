# SLA-Statistik eines Projekts (Reiter "SLA-Statistik").
# Nur erreichbar, wenn SLA fuer das Projekt aktiv ist.
class HelpdeskSlaStatisticsController < ApplicationController
  before_action :find_project_by_project_id
  before_action :authorize
  before_action :require_sla_enabled

  def index
    @period = RedmineExpertHelpdesk::SlaStatistics::PERIODS.include?(params[:period]) ?
                params[:period] : 'month'
    @date_to   = parse_date(params[:date_to])   || Date.current
    @date_from = parse_date(params[:date_from]) || default_from(@period, @date_to)

    @stats = RedmineExpertHelpdesk::SlaStatistics.new(
      @project, :period => @period, :date_from => @date_from, :date_to => @date_to).to_h
  end

  private

  def require_sla_enabled
    render_403 unless HelpdeskProjectSetting.for_project(@project).sla_enabled?
  end

  def parse_date(value)
    Date.iso8601(value.to_s)
  rescue ArgumentError
    nil
  end

  # Sinnvoller Standard-Zeitraum je Gruppierung.
  def default_from(period, to)
    case period
    when 'day'  then to - 30
    when 'week' then to - 7 * 12
    when 'year' then to - 365 * 5
    else             to.prev_month(12)
    end
  end
end
