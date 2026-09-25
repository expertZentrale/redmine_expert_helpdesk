# Manueller Import der Altdaten aus redmine_contacts / redmine_contacts_helpdesk
# (Button in den Plugin-Einstellungen, nur Administratoren).
#
# Import and attachment repair run as HelpdeskLegacyImportJob: the POST only
# records a HelpdeskLegacyImportRun and redirects to its status page, which polls
# #poll until the run finishes. Run inline, both hit the browser /
# reverse-proxy timeout on large legacy datasets.
class HelpdeskLegacyImportController < ApplicationController
  before_action :require_admin
  before_action :redirect_to_current_run, :only => [:new, :import, :attachments, :fix_attachments]
  before_action :find_run, :only => [:show, :poll]

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

    start_run('import', project_ids)
  end

  # EML selection page: per project, how many legacy mails can be moved onto the
  # issue (repair) or handed back to RedmineUP's HelpdeskTicket (restore).
  def attachments
    @redmineup_installed = RedmineExpertHelpdesk::LegacyContactsImport.redmineup_helpdesk_installed?
    @project_options = RedmineExpertHelpdesk::LegacyContactsImport.attachment_project_options
    return unless @project_options.empty?

    flash[:error] = l(:error_helpdesk_legacy_fix_no_data)
    redirect_to plugin_settings_path('redmine_expert_helpdesk')
  end

  # Repair (operation 'fix', default) or restore (operation 'restore') for the
  # selected projects
  def fix_attachments
    project_ids = Array(params[:project_ids]).reject(&:blank?)
    if project_ids.empty?
      flash[:error] = l(:error_helpdesk_legacy_import_no_selection)
      redirect_to helpdesk_legacy_attachments_select_path
      return
    end

    if params[:operation] == 'restore'
      unless RedmineExpertHelpdesk::LegacyContactsImport.redmineup_helpdesk_installed?
        flash[:error] = l(:error_helpdesk_legacy_restore_unavailable)
        redirect_to helpdesk_legacy_attachments_select_path
        return
      end
      start_run('restore_attachments', project_ids)
    else
      start_run('fix_attachments', project_ids)
    end
  end

  def show
  end

  # Polling endpoint of the status page
  def poll
    render :json => run_status(@run)
  end

  private

  def find_run
    @run = HelpdeskLegacyImportRun.find_by(:id => params[:id])
    render_404 unless @run
  end

  # Import and repair both rewrite helpdesk_messages; a second click (or a second
  # admin) joins the live run instead of starting a competing one.
  def redirect_to_current_run
    run = HelpdeskLegacyImportRun.current
    return unless run

    flash[:warning] = l(:notice_helpdesk_legacy_run_already_active)
    redirect_to helpdesk_legacy_import_run_path(run)
    true
  end

  def start_run(kind, project_ids = nil)
    run = HelpdeskLegacyImportRun.claim!(kind, User.current, project_ids)
    # Lost the race against a concurrent start - join that run instead
    return redirect_to_current_run || redirect_to(plugin_settings_path('redmine_expert_helpdesk')) unless run

    HelpdeskLegacyImportJob.perform_later(run.id)
    redirect_to helpdesk_legacy_import_run_path(run)
  rescue StandardError => e
    Rails.logger.error "Helpdesk: could not start legacy #{kind} run: #{e.message}"
    run&.fail!(e.message) if run&.persisted?
    flash[:error] = l(:error_helpdesk_legacy_import_failed, :message => e.message)
    redirect_to plugin_settings_path('redmine_expert_helpdesk')
  end

  def run_status(run)
    status = run.stale? ? 'stale' : run.status
    { :id => run.id, :kind => run.kind, :status => status, :finished => run.finished? || run.stale?,
      :phase => run.phase, :phase_label => (run.phase.present? ? l("label_helpdesk_legacy_phase_#{run.phase}") : nil),
      :progress_done => run.progress_done, :progress_total => run.progress_total,
      :message => status_message(run, status) }
  end

  # Same wording the old synchronous flash used, so the finished page reads as before.
  def status_message(run, status)
    case status
    when 'done'
      r = run.result_hash
      case run.kind
      when 'fix_attachments'
        l(:notice_helpdesk_legacy_fix_done, :fixed => r[:attachments_fixed].to_i,
          :orphaned => r[:attachments_orphaned].to_i, :linked => r[:messages_linked].to_i)
      when 'restore_attachments'
        l(:notice_helpdesk_legacy_restore_done, :restored => r[:attachments_restored].to_i)
      else
        l(:notice_helpdesk_legacy_import_done, :created => r[:contacts_created].to_i,
          :existing => r[:contacts_existing].to_i, :links => r[:issue_links_created].to_i,
          :repaired => r[:issue_links_repaired].to_i, :skipped => r[:issues_skipped].to_i)
      end
    when 'failed' then l(:error_helpdesk_legacy_import_failed, :message => run.error_message)
    when 'stale'  then l(:error_helpdesk_legacy_run_stale)
    when 'queued' then l(:label_helpdesk_legacy_run_queued)
    else l(:label_helpdesk_legacy_run_running)
    end
  end
  helper_method :run_status
end
