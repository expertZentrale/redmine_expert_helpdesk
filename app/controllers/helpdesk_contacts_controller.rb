# Kundenliste und -bearbeitung pro Projekt.
# Erreichbar ueber den Reiter "Kunden" in der Projektnavigation.
class HelpdeskContactsController < ApplicationController
  before_action :find_project_by_project_id
  before_action :authorize
  before_action :find_contact, :only => [:edit, :update, :destroy]

  def index
    per_page_setting = Setting.plugin_redmine_expert_helpdesk['contacts_per_page'].to_i
    per_page_setting = 25 if per_page_setting <= 0
    @per_page = params[:per_page].to_i
    @per_page = per_page_setting if @per_page <= 0
    @per_page = [[@per_page, 5].max, 200].min

    scope = HelpdeskContact.where(:project_id => @project.id)

    # Freitextsuche ueber Name, E-Mail und Firma
    @search = params[:search].to_s.strip
    if @search.present?
      safe = "%#{ActiveRecord::Base.sanitize_sql_like(@search.downcase)}%"
      scope = scope.where('LOWER(name) LIKE ? OR LOWER(email) LIKE ? OR LOWER(company) LIKE ?', safe, safe, safe)
    end

    @contact_count = scope.count
    @contact_pages = Redmine::Pagination::Paginator.new(@contact_count, @per_page, params[:page])
    @contacts = scope
                  .order(:name => :asc, :email => :asc)
                  .includes(:helpdesk_messages)
                  .limit(@per_page)
                  .offset(@contact_pages.offset)
  end

  def edit
    ticket_limit = Setting.plugin_redmine_expert_helpdesk['contact_ticket_limit'].to_i
    @ticket_limit         = ticket_limit > 0 ? ticket_limit : 10
    @contact_issues       = @contact.issues.includes(:status).order(:id => :desc).limit(@ticket_limit)
    @contact_issues_total = @contact.issues.count
  end

  # Gibt passende Kontakte als JSON zurueck (fuer Autocomplete in der Antwort-Maske).
  # Parameter: q (Suchbegriff, mind. 2 Zeichen)
  def autocomplete
    q = params[:q].to_s.strip
    if q.length >= 2
      safe_q = "%#{ActiveRecord::Base.sanitize_sql_like(q.downcase)}%"
      contacts = HelpdeskContact
                   .where(:project_id => @project.id)
                   .where('LOWER(name) LIKE ? OR LOWER(email) LIKE ?', safe_q, safe_q)
                   .order(:name => :asc)
                   .limit(10)
                   .select(:id, :name, :email)
    else
      contacts = []
    end
    render :json => contacts.map { |c|
      name  = c.name.to_s
      email = c.email.to_s
      # RFC 2822: Display-Namen mit Komma muessen gequotet werden
      if name.present?
        display = name.include?(',') ? "\"#{name.gsub('"', '\\"')}\"" : name
        label   = "#{display} <#{email}>"
      else
        label = email
      end
      { :name => name, :email => email, :label => label }
    }
  end

  def update
    @contact.safe_attributes = params[:helpdesk_contact]
    if @contact.save
      flash[:notice] = l(:notice_successful_update)
      redirect_to helpdesk_contacts_path(:project_id => @project)
    else
      render :action => 'edit'
    end
  end

  def destroy
    @contact.destroy
    flash[:notice] = l(:notice_successful_delete)
      redirect_to helpdesk_contacts_path(:project_id => @project)
  end

  private

  def find_contact
    @contact = HelpdeskContact.where(:project_id => @project.id).find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render_404
  end
end
