# SLA-Statistik eines Projekts (Reiter "SLA-Statistik").
# Nur erreichbar, wenn SLA fuer das Projekt aktiv ist.
class HelpdeskSlaStatisticsController < ApplicationController
  before_action :find_project_by_project_id
  before_action :authorize
  before_action :require_sla_enabled

  # Auswaehlbare Zeitraeume; 'custom' zeigt die Datumsfelder.
  RANGES = %w[last_7_days last_30_days last_90_days last_6_months last_12_months last_5_years custom].freeze

  def index
    @period = RedmineExpertHelpdesk::SlaStatistics::PERIODS.include?(params[:period]) ?
                params[:period] : 'month'
    @range = resolve_range
    @date_to, @date_from = range_dates(@range)

    @stats = RedmineExpertHelpdesk::SlaStatistics.new(
      @project, :period => @period, :date_from => @date_from, :date_to => @date_to).to_h
  end

  private

  def require_sla_enabled
    render_403 unless HelpdeskProjectSetting.for_project(@project).sla_enabled?
  end

  # Gewaehlter Zeitraum. Ohne Angabe: Standard (Jahresansicht), aber
  # explizite Datumsparameter (z. B. Link/Bookmark) gelten als 'custom'.
  def resolve_range
    r = params[:range].presence
    return r if RANGES.include?(r)

    params[:date_from].present? ? 'custom' : 'last_12_months'
  end

  # Liefert [date_to, date_from] fuer den gewaehlten Zeitraum.
  def range_dates(range)
    to = Date.current
    case range
    when 'last_7_days'    then [to, to - 7]
    when 'last_30_days'   then [to, to - 30]
    when 'last_90_days'   then [to, to - 90]
    when 'last_6_months'  then [to, to.prev_month(6)]
    when 'last_12_months' then [to, to.prev_month(12)]
    when 'last_5_years'   then [to, to.prev_year(5)]
    else # custom
      dto = parse_date(params[:date_to]) || Date.current
      [dto, parse_date(params[:date_from]) || default_from(@period, dto)]
    end
  end

  def parse_date(value)
    Date.iso8601(value.to_s)
  rescue ArgumentError
    nil
  end

  # Sinnvoller Standard-Zeitraum je Gruppierung (nur fuer 'custom' ohne Von-Datum).
  def default_from(period, to)
    case period
    when 'day'  then to - 30
    when 'week' then to - 7 * 12
    when 'year' then to - 365 * 5
    else             to.prev_month(12)
    end
  end
end
