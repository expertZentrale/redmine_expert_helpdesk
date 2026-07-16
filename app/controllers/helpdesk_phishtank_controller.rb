# Manueller Phishing-Feed-Sync aus den Plugin-Einstellungen (nur Administratoren).
class HelpdeskPhishtankController < ApplicationController
  before_action :require_admin

  def sync
    settings = Setting.plugin_redmine_expert_helpdesk
    if settings['phishtank_enabled'] != '1'
      flash[:error] = l(:error_helpdesk_phishtank_disabled)
    else
      results, errors = RedmineExpertHelpdesk::PhishingFeeds.run_all
      if results.any?
        summary = results.map { |source, count| "#{source}: #{count}" }.join(', ')
        flash[:notice] = l(:notice_helpdesk_phishing_sync_done, :summary => summary)
      end
      if errors.any?
        message = errors.map { |source, msg| "#{source}: #{msg}" }.join('; ')
        flash[:error] = l(:error_helpdesk_phishing_sync_failed, :message => message)
      end
    end

    redirect_to plugin_settings_path('redmine_expert_helpdesk')
  end
end
