# Manueller Import der Altdaten aus redmine_contacts / redmine_contacts_helpdesk
# (Button in den Plugin-Einstellungen, nur Administratoren).
class HelpdeskLegacyImportController < ApplicationController
  before_action :require_admin

  # Auswahlseite: welche Projekte (Alt-Kontakte) sollen importiert werden?
  def new
    unless RedmineExpertHelpdesk::LegacyContactsImport.available?
      flash[:error] = l(:error_helpdesk_legacy_import_no_data)
      redirect_to plugin_settings_path('redmine_expert_helpdesk')
      return
    end

    @project_options = RedmineExpertHelpdesk::LegacyContactsImport.legacy_project_options
  end

  def import
    unless RedmineExpertHelpdesk::LegacyContactsImport.available?
      flash[:error] = l(:error_helpdesk_legacy_import_no_data)
      redirect_to plugin_settings_path('redmine_expert_helpdesk')
      return
    end

    project_ids = Array(params[:project_ids]).reject(&:blank?)
    if project_ids.empty?
      flash[:error] = l(:error_helpdesk_legacy_import_no_selection)
      redirect_to helpdesk_legacy_import_select_path
      return
    end

    result = RedmineExpertHelpdesk::LegacyContactsImport.new(project_ids).run
    flash[:notice] = l(:notice_helpdesk_legacy_import_done,
                       :created  => result.contacts_created,
                       :existing => result.contacts_existing,
                       :links    => result.issue_links_created,
                       :repaired => result.issue_links_repaired,
                       :skipped  => result.issues_skipped)
    redirect_to plugin_settings_path('redmine_expert_helpdesk')
  rescue StandardError => e
    Rails.logger.error "Helpdesk: Legacy-Kontaktimport fehlgeschlagen: #{e.message}"
    flash[:error] = l(:error_helpdesk_legacy_import_failed, :message => e.message)
    redirect_to plugin_settings_path('redmine_expert_helpdesk')
  end

  # Haengt Alt-Anhaenge (container_type 'HelpdeskTicket') an die Tickets um
  def fix_attachments
    if RedmineExpertHelpdesk::LegacyContactsImport.misplaced_attachment_count.zero?
      flash[:error] = l(:error_helpdesk_legacy_fix_no_data)
      redirect_to plugin_settings_path('redmine_expert_helpdesk')
      return
    end

    result = RedmineExpertHelpdesk::LegacyContactsImport.new.fix_attachments
    flash[:notice] = l(:notice_helpdesk_legacy_fix_done,
                       :fixed    => result.attachments_fixed,
                       :orphaned => result.attachments_orphaned,
                       :linked   => result.messages_linked)
    redirect_to plugin_settings_path('redmine_expert_helpdesk')
  rescue StandardError => e
    Rails.logger.error "Helpdesk: EML-Anhang-Reparatur fehlgeschlagen: #{e.message}"
    flash[:error] = l(:error_helpdesk_legacy_import_failed, :message => e.message)
    redirect_to plugin_settings_path('redmine_expert_helpdesk')
  end
end
