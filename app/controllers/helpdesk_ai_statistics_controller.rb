# Projektbezogene KI-Statistik (KI-Nutzung/Kostenrisiko). Zugriff nur mit der
# globalen Berechtigung view_helpdesk_ai_statistics (typischerweise eine Rolle
# "ai-admin"), unabhaengig von der Projektmitgliedschaft. @project wird nur zum
# Filtern der Daten geladen.
class HelpdeskAiStatisticsController < ApplicationController
  include HelpdeskStatsDateRange

  before_action :find_project_by_project_id
  before_action :require_ai_features_enabled
  before_action :require_ai_stats_permission

  def index
    @period = RedmineExpertHelpdesk::AiUsageStatistics::PERIODS.include?(params[:period]) ?
                params[:period] : 'month'
    @range = resolve_range
    @date_to, @date_from = range_dates(@range)

    @stats = RedmineExpertHelpdesk::AiUsageStatistics.new(
      @project, :period => @period, :date_from => @date_from, :date_to => @date_to).to_h
  end

  private

  # Mirrors the menu gate in init.rb: with both AI and the knowledge base off the page has
  # nothing to show, so the URL must not be reachable by hand either.
  def require_ai_features_enabled
    render_403 unless RedmineExpertHelpdesk::AiFeatures.any_enabled?
  end

  def require_ai_stats_permission
    render_403 unless User.current.allowed_to?(:view_helpdesk_ai_statistics, nil, :global => true)
  end
end
