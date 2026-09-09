# Kundenliste und -bearbeitung pro Projekt.
# Erreichbar ueber den Reiter "Kunden" in der Projektnavigation.
class HelpdeskContactsController < ApplicationController
  before_action :find_project_by_project_id
  before_action :authorize
  before_action :find_contact, :only => [:edit, :update, :destroy, :toggle_info_request]

  helper :sort
  include SortHelper

  # Sortable columns of the customer list. Ticket count and last ticket are
  # derived from the contact's messages (same definition as the list cells), so
  # they sort through correlated subqueries.
  TICKET_COUNT_SQL = "(SELECT COUNT(DISTINCT hm.issue_id) FROM helpdesk_messages hm" \
                     " WHERE hm.helpdesk_contact_id = helpdesk_contacts.id)".freeze
  LAST_TICKET_SQL  = "(SELECT MAX(hm.sent_at) FROM helpdesk_messages hm" \
                     " WHERE hm.helpdesk_contact_id = helpdesk_contacts.id)".freeze
  SORT_COLUMNS = {
    'name'         => 'helpdesk_contacts.name',
    'email'        => 'helpdesk_contacts.email',
    'company'      => 'helpdesk_contacts.company',
    'phone'        => 'helpdesk_contacts.phone',
    'ticket_count' => TICKET_COUNT_SQL,
    'last_ticket'  => LAST_TICKET_SQL
  }.freeze

  def index
    sort_init 'name', 'asc'
    sort_update SORT_COLUMNS

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
    # sort_clause carries raw subquery SQL, hence Arel.sql; email as tie-breaker.
    order = (Array(sort_clause) + ['helpdesk_contacts.email ASC']).join(', ')
    @contacts = scope
                  .order(Arel.sql(order))
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

  # "Never ask this customer for more information" toggled straight from the ticket
  # header bar. The same flag as the checkbox on the edit form - agents meet this
  # decision on a Veeam report they are looking at, not in the customer list, and a
  # detour through the form loses the ticket they came from.
  def toggle_info_request
    @contact.update_column(:info_request_opt_out, !@contact.info_request_opt_out?)
    flash[:notice] = l(:notice_successful_update)
    redirect_back_or_default helpdesk_contacts_path(:project_id => @project)
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
