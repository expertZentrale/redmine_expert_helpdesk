# CRUD fuer die Postfach-Konfiguration (Reiter "Helpdesk" in den Projekteinstellungen)
class HelpdeskMailboxesController < ApplicationController
  AJAX_ACTIONS = [:folders, :create_folder, :test_connection].freeze

  before_action :find_project_by_project_id
  before_action :authorize, :except => AJAX_ACTIONS
  before_action :require_manage_mailboxes, :only => AJAX_ACTIONS
  before_action :find_mailbox, :only => [:edit, :update, :destroy, :oauth_authorize]

  def new
    @mailbox = @project.helpdesk_mailboxes.build
  end

  def create
    @mailbox = @project.helpdesk_mailboxes.build
    @mailbox.safe_attributes = params[:helpdesk_mailbox]
    if @mailbox.save
      ensure_mailbox_folders(@mailbox)
      flash[:notice] = l(:notice_successful_create)
      redirect_to settings_project_path(@project, :tab => 'expert_helpdesk')
    else
      render :action => 'new'
    end
  end

  def edit
  end

  def update
    @mailbox.safe_attributes = params[:helpdesk_mailbox]
    if @mailbox.save
      ensure_mailbox_folders(@mailbox)
      flash[:notice] = l(:notice_successful_update)
      redirect_to settings_project_path(@project, :tab => 'expert_helpdesk')
    else
      render :action => 'edit'
    end
  end

  def destroy
    @mailbox.destroy
    flash[:notice] = l(:notice_successful_delete)
    redirect_to settings_project_path(@project, :tab => 'expert_helpdesk')
  end

  # Liefert JSON-Array aller Ordnernamen fuer das angegebene Postfach (AJAX).
  def folders
    provider = draft_provider
    return render :json => { :error => l(:error_helpdesk_provider_not_configured) }, :status => 422 unless provider

    render :json => provider.list_folders
  rescue RedmineExpertHelpdesk::MailProvider::ProviderError => e
    render :json => { :error => e.message }, :status => 422
  end

  # Legt einen neuen Ordner im Postfach an (AJAX, POST).
  def create_folder
    folder_name = params[:folder_name].to_s.strip
    return render :json => { :error => l(:error_helpdesk_missing_parameters) }, :status => 422 if folder_name.blank?

    provider = draft_provider
    return render :json => { :error => l(:error_helpdesk_provider_not_configured) }, :status => 422 unless provider

    provider.create_folder(folder_name)
    render :json => { :success => true, :name => folder_name }
  rescue RedmineExpertHelpdesk::MailProvider::ProviderError => e
    render :json => { :error => e.message }, :status => 422
  end

  # Prueft Verbindung und Anmeldung des (noch ungespeicherten) Postfachs (AJAX, POST).
  def test_connection
    provider = draft_provider
    return render :json => { :ok => false, :message => l(:error_helpdesk_provider_not_configured) }, :status => 422 unless provider

    render :json => provider.test_connection
  end

  # Startet den OAuth-Consent (authorization_code) fuer ein gespeichertes Postfach.
  def oauth_authorize
    redirect_to expert_helpdesk_oauth_authorize_path(:mailbox_id => @mailbox.id)
  end

  private

  # Builds a provider from the submitted form state, falling back to the
  # persisted record. Secrets of a saved mailbox are read from the database, so
  # they never have to travel back to the browser.
  #
  # This deliberately replaces the previous behaviour of trusting an arbitrary
  # mailbox_address parameter, which allowed listing the folders of any mailbox
  # the global app registration could reach.
  def draft_provider
    mailbox = persisted_mailbox || @project.helpdesk_mailboxes.build
    attrs = params[:helpdesk_mailbox]
    mailbox.safe_attributes = attrs if attrs.present?
    return nil if mailbox.mailbox_address.blank?

    provider = RedmineExpertHelpdesk::MailProvider.for(mailbox)
    provider.configured? ? provider : nil
  end

  def persisted_mailbox
    id = params[:id].presence || params[:mailbox_id].presence
    return @project.helpdesk_mailboxes.find_by(:id => id) if id.present?

    # Legacy GET callers still pass only the address. Resolving it against this
    # project's own mailboxes keeps that working without trusting the value.
    address = params[:mailbox_address].presence
    address ? @project.helpdesk_mailboxes.find_by(:mailbox_address => address) : nil
  end

  # Stellt sicher, dass alle konfigurierten Zielordner im Postfach existieren.
  # Fehlende Ordner werden automatisch angelegt. Fehler werden als Warnung gemeldet.
  def ensure_mailbox_folders(mailbox)
    error = RedmineExpertHelpdesk::MailboxFolders.ensure!(mailbox)
    flash[:warning] = l(:warning_helpdesk_folder_create_failed, :message => error) if error
  end

  def require_manage_mailboxes
    unless User.current.allowed_to?(:manage_helpdesk, @project)
      render :json => { :error => l(:error_helpdesk_access_denied) }, :status => 403
    end
  end

  def find_mailbox
    @mailbox = @project.helpdesk_mailboxes.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render_404
  end
end
