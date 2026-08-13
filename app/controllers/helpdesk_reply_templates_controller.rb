# CRUD fuer Antwortvorlagen ("Textbausteine").
#
# Zwei Geltungsbereiche ueber denselben Controller: mit project_id gehoert die
# Vorlage dem Projekt (Reiter "expert Helpdesk" in den Projekteinstellungen,
# Berechtigung manage_helpdesk), ohne project_id ist sie global und wird in der
# Plugin-Verwaltung gepflegt (nur Administratoren).
class HelpdeskReplyTemplatesController < ApplicationController
  before_action :find_project_scope
  before_action :authorize_templates
  before_action :find_template, :only => [:edit, :update, :destroy]

  def index
    @templates =
      if @project
        HelpdeskReplyTemplate.where(:project_id => @project.id).order(:position, :name)
      else
        HelpdeskReplyTemplate.global.order(:position, :name)
      end
  end

  def new
    @template = HelpdeskReplyTemplate.new(:project_id => @project&.id, :enabled => true)
  end

  def create
    @template = HelpdeskReplyTemplate.new(:project_id => @project&.id)
    @template.safe_attributes = params[:helpdesk_reply_template]
    if @template.save
      flash[:notice] = l(:notice_successful_create)
      redirect_to back_path
    else
      render :action => 'new'
    end
  end

  def edit
  end

  def update
    @template.safe_attributes = params[:helpdesk_reply_template]
    if @template.save
      flash[:notice] = l(:notice_successful_update)
      redirect_to back_path
    else
      render :action => 'edit'
    end
  end

  def destroy
    @template.destroy
    flash[:notice] = l(:notice_successful_delete)
    redirect_to back_path
  end

  private

  # project_id ist optional: fehlt er, verwaltet der Aufruf globale Vorlagen.
  def find_project_scope
    return if params[:project_id].blank?

    @project = Project.find(params[:project_id])
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  def authorize_templates
    if @project
      deny_access unless @project.module_enabled?(:helpdesk) &&
                         User.current.allowed_to?(:manage_helpdesk, @project)
    else
      require_admin
    end
  end

  def find_template
    scope = @project ? HelpdeskReplyTemplate.where(:project_id => @project.id) : HelpdeskReplyTemplate.global
    @template = scope.find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  # Zurueck dorthin, wo die Vorlagen gepflegt werden.
  def back_path
    if @project
      settings_project_path(@project, :tab => 'expert_helpdesk')
    else
      plugin_settings_path(:redmine_expert_helpdesk)
    end
  end
end
