# Ausloesen des Mailabrufs:
#   - fetch:     Button in den Projekteinstellungen (Berechtigung :fetch_helpdesk_mail)
#   - fetch_all: Globaler Endpunkt fuer curl/CronJob, gesichert per statischem API-Key
class HelpdeskFetchController < ApplicationController
  before_action :find_project_by_project_id, :only => [:fetch]
  before_action :authorize, :only => [:fetch]

  skip_before_action :check_if_login_required, :only => [:fetch_all, :sla_check]
  skip_before_action :verify_authenticity_token, :only => [:fetch_all, :sla_check]

  def fetch
    results = @project.helpdesk_mailboxes.enabled.map do |mailbox|
      result = RedmineExpertHelpdesk::MailProcessor.new(mailbox).process_all
      [mailbox.mailbox_address, result.to_h]
    end.to_h

    respond_to do |format|
      format.html do
        flash[:notice] = l(:notice_helpdesk_fetch_done, :count => results.values.sum { |r| r[:processed] })
        redirect_to settings_project_path(@project, :tab => 'helpdesk')
      end
      format.json { render :json => results }
    end
  rescue RedmineExpertHelpdesk::GraphClient::GraphError => e
    respond_to do |format|
      format.html do
        flash[:error] = l(:error_helpdesk_fetch_failed, :message => e.message)
        redirect_to settings_project_path(@project, :tab => 'helpdesk')
      end
      format.json { render :json => { :error => e.message }, :status => 502 }
    end
  end

  def fetch_all
    unless valid_api_key?('fetch_api_key')
      render :json => { :error => 'Ungueltiger API-Key' }, :status => 401
      return
    end

    summary = {}
    HelpdeskMailbox.enabled.includes(:project).each do |mailbox|
      next unless mailbox.project&.active? && mailbox.project.module_enabled?(:helpdesk)

      begin
        summary[mailbox.mailbox_address] = RedmineExpertHelpdesk::MailProcessor.new(mailbox).process_all.to_h
      rescue StandardError => e
        Rails.logger.error "Helpdesk: Abruf fuer #{mailbox.mailbox_address} fehlgeschlagen: #{e.message}"
        summary[mailbox.mailbox_address] = { :error => e.message }
      end
    end

    # Phishing-Feeds bei Bedarf aktualisieren (Piggyback auf den Cron-Abruf).
    # Fehler duerfen den Mailabruf nie beeintraechtigen.
    begin
      RedmineExpertHelpdesk::PhishingFeeds.run_if_stale
    rescue StandardError => e
      Rails.logger.error "Helpdesk: Feed-Sync im fetch_all fehlgeschlagen: #{e.message}"
    end

    render :json => { :fetched_at => Time.current.iso8601, :mailboxes => summary }
  end

  # Globale SLA-Pruefung fuer einen externen CronJob (z. B. via curl), gesichert
  # per eigenem API-Key. Loest ausschliesslich die SLA-Ueberschreitungspruefung
  # aus; ueberlappende Laeufe werden per Cache-Lock in run_if_due verhindert.
  def sla_check
    unless valid_api_key?('sla_api_key')
      render :json => { :error => 'Ungueltiger API-Key' }, :status => 401
      return
    end

    notified = RedmineExpertHelpdesk::SlaBreachCheck.run_if_due

    if notified == false
      # Lock gehalten => ein anderer Lauf ist aktiv, kein ueberlappender Check
      render :json => { :checked_at => Time.current.iso8601, :skipped => true }
    else
      render :json => { :checked_at => Time.current.iso8601, :notified => notified }
    end
  end

  private

  # Timing-sicherer Vergleich des uebergebenen ?key= gegen die in den
  # Plugin-Einstellungen hinterlegte API-Key-Einstellung. Leerer/fehlender
  # konfigurierter Key => Endpunkt deaktiviert (Vergleich schlaegt fehl).
  def valid_api_key?(setting_key)
    configured = Setting.plugin_redmine_expert_helpdesk[setting_key].to_s
    provided   = params[:key].to_s

    configured.present? && provided.present? &&
      ActiveSupport::SecurityUtils.secure_compare(configured, provided)
  end
end
