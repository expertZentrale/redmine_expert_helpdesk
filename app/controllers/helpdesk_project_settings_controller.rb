# Speichert projekt-spezifische Helpdesk-Einstellungen aus dem Projekteinstellungen-Tab.
class HelpdeskProjectSettingsController < ApplicationController
  before_action :find_project_by_project_id
  before_action :require_manage_helpdesk

  def update
    setting = HelpdeskProjectSetting.find_or_initialize_by(:project_id => @project.id)

    sla_form = params[:sla_form].present?
    if sla_form
      update_sla_settings(setting)
    else
      update_reply_settings(setting)
    end

    setting.save!

    # Zielzeiten/Arbeitszeiten koennen sich geaendert haben -> vorberechnete
    # SLA-Faelligkeiten der offenen Tickets neu berechnen (fuer Grid-Spalten/-Filter).
    RedmineExpertHelpdesk::Sla.refresh_project_deadlines!(@project) if sla_form

    flash[:notice] = l(:notice_successful_update)
    redirect_to :controller => 'projects', :action => 'settings',
                :id => @project, :tab => 'helpdesk'
  rescue => e
    flash[:error] = e.message
    redirect_to :controller => 'projects', :action => 'settings',
                :id => @project, :tab => 'helpdesk'
  end

  private

  # Antwort- und Phishing-Einstellungen (erstes Formular im Tab)
  def update_reply_settings(setting)
    setting.send_reply_by_default =
      params.dig(:helpdesk_project_setting, :send_reply_by_default) == '1'
    subject = params.dig(:helpdesk_project_setting, :reply_subject_template).to_s.strip
    setting.reply_subject_template =
      subject.presence || HelpdeskProjectSetting::DEFAULT_SUBJECT_TEMPLATE
    setting.reply_status_id =
      params.dig(:helpdesk_project_setting, :reply_status_id).presence
    setting.reply_assign_to_sender =
      params.dig(:helpdesk_project_setting, :reply_assign_to_sender) == '1'
    setting.phishing_check_enabled =
      params.dig(:helpdesk_project_setting, :phishing_check_enabled) == '1'
    action = params.dig(:helpdesk_project_setting, :phishing_action).to_s
    setting.phishing_action = action if HelpdeskProjectSetting::PHISHING_ACTIONS.include?(action)
  end

  # SLA-Einstellungen (zweites Formular im Tab) inkl. Prioritaets-Overrides
  def update_sla_settings(setting)
    hp = params[:helpdesk_project_setting] || {}

    was_enabled = setting.sla_enabled?
    setting.sla_enabled = hp[:sla_enabled] == '1'
    # Aktivierungszeitpunkt merken: SLA gilt nur fuer Tickets ab diesem Datum
    setting.sla_enabled_at = Time.current if setting.sla_enabled? && !was_enabled

    setting.sla_reaction_minutes = hp[:sla_reaction_minutes].presence
    setting.sla_solution_minutes = hp[:sla_solution_minutes].presence
    setting.sla_work_days  = Array(hp[:sla_work_days]).map(&:to_i).select { |d| (1..7).cover?(d) }.join(',')
    setting.sla_work_start = hp[:sla_work_start].to_s.strip.presence || '08:00'
    setting.sla_work_end   = hp[:sla_work_end].to_s.strip.presence || '17:00'
    setting.sla_notify_enabled = hp[:sla_notify_enabled] == '1'
    setting.sla_notify_email   = hp[:sla_notify_email].to_s.strip.presence
    setting.sla_notify_user_id = hp[:sla_notify_user_id].presence

    update_sla_priorities
  end

  # Prioritaets-Overrides: leere Zeilen loeschen, gefuellte anlegen/aktualisieren
  def update_sla_priorities
    (params[:sla_priorities] || {}).each do |priority_id, values|
      reaction = values[:reaction_minutes].presence
      solution = values[:solution_minutes].presence
      override = HelpdeskSlaPriority.find_or_initialize_by(
        :project_id => @project.id, :priority_id => priority_id.to_i
      )

      if reaction.nil? && solution.nil?
        override.destroy if override.persisted?
      else
        override.reaction_minutes = reaction
        override.solution_minutes = solution
        override.save!
      end
    end
  end

  def require_manage_helpdesk
    unless User.current.allowed_to?(:manage_helpdesk, @project)
      deny_access
    end
  end
end
