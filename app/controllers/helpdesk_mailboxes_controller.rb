# CRUD fuer die Postfach-Konfiguration (Reiter "Helpdesk" in den Projekteinstellungen)
class HelpdeskMailboxesController < ApplicationController
  before_action :find_project_by_project_id
  before_action :authorize, :except => [:folders, :create_folder]
  before_action :require_manage_mailboxes, :only => [:folders, :create_folder]
  before_action :find_mailbox, :only => [:edit, :update, :destroy]

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
    mailbox_address = params[:mailbox_address].to_s.strip
    return render :json => [] if mailbox_address.blank?

    client = RedmineExpertHelpdesk::GraphClient.new
    unless client.configured?
      return render :json => { :error => 'Helpdesk-Plugin nicht konfiguriert' }, :status => 422
    end

    render :json => client.list_folders(mailbox_address)
  rescue RedmineExpertHelpdesk::GraphClient::GraphError => e
    render :json => { :error => e.message }, :status => 422
  end

  # Legt einen neuen Ordner im Postfach an (AJAX, POST).
  def create_folder
    mailbox_address = params[:mailbox_address].to_s.strip
    folder_name     = params[:folder_name].to_s.strip

    if mailbox_address.blank? || folder_name.blank?
      return render :json => { :error => 'Parameter fehlen' }, :status => 422
    end

    client = RedmineExpertHelpdesk::GraphClient.new
    unless client.configured?
      return render :json => { :error => 'Helpdesk-Plugin nicht konfiguriert' }, :status => 422
    end

    client.create_folder(mailbox_address, folder_name)
    render :json => { :success => true, :name => folder_name }
  rescue RedmineExpertHelpdesk::GraphClient::GraphError => e
    render :json => { :error => e.message }, :status => 422
  end

  private

  # Stellt sicher, dass alle konfigurierten Zielordner im Postfach existieren.
  # Fehlende Ordner werden automatisch angelegt. Fehler werden als Warnung gemeldet.
  def ensure_mailbox_folders(mailbox)
    return unless mailbox.mailbox_address.present?

    client = RedmineExpertHelpdesk::GraphClient.new
    return unless client.configured?

    folders = [mailbox.processed_folder, mailbox.skipped_folder, mailbox.failed_folder].compact.uniq
    folders.each do |folder|
      next if folder.blank?
      client.find_or_create_folder(mailbox.mailbox_address, folder)
    end
  rescue RedmineExpertHelpdesk::GraphClient::GraphError,
         RedmineExpertHelpdesk::GraphClient::ConfigurationError => e
    flash[:warning] = l(:warning_helpdesk_folder_create_failed, :message => e.message)
  end

  def require_manage_mailboxes
    unless User.current.allowed_to?(:manage_helpdesk, @project)
      render :json => { :error => 'Zugriff verweigert' }, :status => 403
    end
  end

  def find_mailbox
    @mailbox = @project.helpdesk_mailboxes.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render_404
  end
end
