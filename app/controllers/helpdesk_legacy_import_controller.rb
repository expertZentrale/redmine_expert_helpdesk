# Manueller Import der Altdaten aus redmine_contacts / redmine_contacts_helpdesk
# (Button in den Plugin-Einstellungen, nur Administratoren).
#
# Import and attachment repair run as HelpdeskLegacyImportJob: the POST only
# records a HelpdeskLegacyImportRun and redirects to its status page, which polls
# #poll until the run finishes. Run inline, both hit the browser /
# reverse-proxy timeout on large legacy datasets.
class HelpdeskLegacyImportController < ApplicationController
  before_action :require_admin
  before_action :redirect_to_current_run, :only => [:new, :import, :fix_attachments]
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

  # Haengt Alt-Anhaenge (container_type 'HelpdeskTicket') an die Tickets um
  def fix_attachments
    if RedmineExpertHelpdesk::LegacyContactsImport.misplaced_attachment_count.zero?
      flash[:error] = l(:error_helpdesk_legacy_fix_no_data)
      redirect_to plugin_settings_path('redmine_expert_helpdesk')
      return
    end

    start_run('fix_attachments')
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
  end

  def start_run(kind, project_ids = nil)
    run = HelpdeskLegacyImportRun.new(:kind => kind, :status => 'queued', :user => User.current)
    run.project_id_list = project_ids
    run.save!
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
      if run.kind == 'fix_attachments'
        l(:notice_helpdesk_legacy_fix_done, :fixed => r[:attachments_fixed].to_i,
          :orphaned => r[:attachments_orphaned].to_i, :linked => r[:messages_linked].to_i)
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
