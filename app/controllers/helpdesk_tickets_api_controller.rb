# REST-API fuer Helpdesk-Tickets (= Redmine-Issues mit Helpdesk-Zusatzdaten:
# Kunde, Postfach, SLA-Zustand, Nachrichtenverlauf). JSON/XML via .api.rsb.
#
# Die Issue-Persistenz delegiert an das Redmine-Issue-Modell (safe_attributes),
# es wird keine Ticket-Logik nachgebaut. Autorisierung nutzt die Kern-Issue-
# Berechtigungen (view/add/edit/delete_issues) plus aktives Helpdesk-Modul.
class HelpdeskTicketsApiController < ApplicationController
  before_action :find_project_by_project_id, :only => [:index, :create]
  before_action :find_ticket,                :only => [:show, :update, :destroy]
  before_action :require_helpdesk_module
  before_action :authorize_view,   :only => [:index, :show]
  before_action :authorize_add,    :only => [:create]
  before_action :authorize_edit,   :only => [:update]
  before_action :authorize_delete, :only => [:destroy]
  accept_api_auth :index, :show, :create, :update, :destroy

  def index
    scope = Issue.visible.where(:project_id => @project.id).where(
      "EXISTS (SELECT 1 FROM helpdesk_ticket_infos ti WHERE ti.issue_id = #{Issue.quoted_table_name}.id)"
    )
    @offset, @limit = api_offset_and_limit
    @issue_count = scope.count
    @issues = scope.includes(:project, :tracker, :status, :priority, :author, :assigned_to)
                   .order(:id => :desc).limit(@limit).offset(@offset).to_a

    @infos = HelpdeskTicketInfo.where(:issue_id => @issues.map(&:id))
                               .includes(:helpdesk_contact, :helpdesk_mailbox).index_by(&:issue_id)
    @sla_by_issue = @issues.each_with_object({}) do |issue, h|
      h[issue.id] = RedmineExpertHelpdesk::Sla.state_for(issue, @infos[issue.id])
    end
    respond_to { |format| format.api }
  end

  def show
    load_ticket_associations
    respond_to { |format| format.api }
  end

  def create
    @issue = Issue.new(:project => @project, :author => User.current)
    @issue.safe_attributes = params[:helpdesk_ticket] || {}
    if @issue.save
      assign_contact(@issue)
      load_ticket_associations
      respond_to { |format| format.api { render :action => 'show', :status => :created } }
    else
      render_validation_errors(@issue)
    end
  end

  def update
    @issue.init_journal(User.current, params[:helpdesk_ticket].try(:[], :notes))
    @issue.safe_attributes = params[:helpdesk_ticket] || {}
    if @issue.save
      assign_contact(@issue)
      render_api_ok
    else
      render_validation_errors(@issue)
    end
  end

  def destroy
    # Helpdesk-Zusatzdaten entfernen, damit keine verwaisten Zeilen bleiben.
    HelpdeskTicketInfo.where(:issue_id => @issue.id).delete_all
    HelpdeskMessage.where(:issue_id => @issue.id).update_all(:issue_id => nil)
    @issue.destroy
    render_api_ok
  end

  private

  def find_ticket
    @issue = Issue.visible.find(params[:id])
    @project = @issue.project
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  def load_ticket_associations
    @info = HelpdeskTicketInfo.for_issue(@issue)
    @sla  = RedmineExpertHelpdesk::Sla.state_for(@issue, @info)
    @messages =
      if params[:include].to_s.split(',').include?('messages')
        HelpdeskMessage.where(:issue_id => @issue.id).order(:id => :asc).to_a
      else
        []
      end
  end

  # Optionale Kundenzuordnung ueber contact_id oder contact_email.
  def assign_contact(issue)
    attrs = params[:helpdesk_ticket] || {}
    contact =
      if attrs[:contact_id].present?
        HelpdeskContact.where(:project_id => issue.project_id).find_by(:id => attrs[:contact_id])
      elsif attrs[:contact_email].present?
        HelpdeskContact.find_or_create_for(attrs[:contact_email], attrs[:contact_name], issue.project)
      end
    return unless contact

    HelpdeskTicketInfo.link!(issue, contact)
    RedmineExpertHelpdesk::Sla.refresh_deadlines!(issue)
  end

  def require_helpdesk_module
    render_403 unless @project && @project.module_enabled?(:helpdesk)
  end

  def authorize_view;   deny_access unless User.current.allowed_to?(:view_issues,   @project); end
  def authorize_add;    deny_access unless User.current.allowed_to?(:add_issues,    @project); end
  def authorize_edit;   deny_access unless User.current.allowed_to?(:edit_issues,   @project); end
  def authorize_delete; deny_access unless User.current.allowed_to?(:delete_issues, @project); end
end
