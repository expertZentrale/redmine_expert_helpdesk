require File.expand_path('../../test_helper', __FILE__)

# Integrationstests der REST-API (Auth via X-Redmine-API-Key, JSON).
# Create-faehige Routen werden vollstaendig geprueft: anlegen -> verifizieren ->
# loeschen -> als geloescht bestaetigen. Laeuft nur in einer Redmine-Testumgebung.
class HelpdeskApiTest < Redmine::IntegrationTest
  fixtures :projects, :users, :email_addresses, :members, :member_roles, :roles,
           :enabled_modules, :trackers, :projects_trackers, :issue_statuses,
           :enumerations, :issues

  def setup
    Setting.rest_api_enabled = '1'
    @project = Project.find(1)
    @project.enable_module!(:helpdesk)
    Role.find(1).add_permission!(:view_helpdesk_info, :manage_helpdesk_contacts, :manage_helpdesk,
                                 :view_issues, :add_issues, :edit_issues, :delete_issues)
    @user = User.find(2) # jsmith, Manager in Projekt 1
    @key  = @user.api_key
  end

  def teardown
    Setting.rest_api_enabled = '0'
  end

  def auth
    { 'X-Redmine-API-Key' => @key }
  end

  # --- Basis / Auth ---------------------------------------------------------

  def test_contacts_index_requires_authentication
    get "/projects/#{@project.id}/helpdesk/contacts.json"
    assert_response :unauthorized
  end

  def test_api_disabled_rejects_key
    # Bei deaktivierter REST-API ignoriert Redmine den Key und antwortet in
    # require_login (format.api) mit 403 Forbidden (nicht 401) — Core-Verhalten.
    Setting.rest_api_enabled = '0'
    get "/projects/#{@project.id}/helpdesk/contacts.json", :headers => auth
    assert_response :forbidden
  end

  def test_contact_create_forbidden_without_permission
    Role.find(1).remove_permission!(:manage_helpdesk_contacts)
    post "/projects/#{@project.id}/helpdesk/contacts.json",
         :params => { :helpdesk_contact => { :email => 'x@example.com' } }, :headers => auth
    assert_response :forbidden
  end

  # --- Kontakt: anlegen -> verifizieren -> loeschen -------------------------

  def test_contact_lifecycle
    # anlegen
    assert_difference 'HelpdeskContact.count', 1 do
      post "/projects/#{@project.id}/helpdesk/contacts.json",
           :params => { :helpdesk_contact => { :email => 'new@example.com', :name => 'New', :company => 'Acme' } },
           :headers => auth
    end
    assert_response :created
    id = ActiveSupport::JSON.decode(@response.body)['helpdesk_contact']['id']

    # verifizieren (Show)
    get "/helpdesk/contacts/#{id}.json", :headers => auth
    assert_response :success
    body = ActiveSupport::JSON.decode(@response.body)['helpdesk_contact']
    assert_equal 'new@example.com', body['email']
    assert_equal 'Acme', body['company']

    # loeschen
    assert_difference 'HelpdeskContact.count', -1 do
      delete "/helpdesk/contacts/#{id}.json", :headers => auth
    end
    assert_response :no_content

    # als geloescht bestaetigen
    get "/helpdesk/contacts/#{id}.json", :headers => auth
    assert_response :not_found
  end

  # --- Ticket: anlegen -> verifizieren -> loeschen --------------------------

  def test_ticket_lifecycle
    # anlegen (Issue + Kunde per contact_email)
    assert_difference 'Issue.count', 1 do
      post "/projects/#{@project.id}/helpdesk/tickets.json",
           :params => { :helpdesk_ticket => {
             :subject => 'API lifecycle', :tracker_id => 1,
             :contact_email => 'ticket@example.com', :contact_name => 'Ticket Contact'
           } }, :headers => auth
    end
    assert_response :created
    ticket = ActiveSupport::JSON.decode(@response.body)['helpdesk_ticket']
    id = ticket['id']
    assert_equal 'API lifecycle', ticket['subject']
    assert_equal 'ticket@example.com', ticket['contact']['email']
    assert HelpdeskTicketInfo.for_issue(Issue.find(id)), 'ticket info linked'

    # verifizieren (Show + messages)
    get "/helpdesk/tickets/#{id}.json?include=messages", :headers => auth
    assert_response :success
    body = ActiveSupport::JSON.decode(@response.body)['helpdesk_ticket']
    assert_equal id, body['id']
    assert body.key?('messages')

    # loeschen (raeumt Helpdesk-Zusatzdaten mit ab)
    assert_difference 'Issue.count', -1 do
      delete "/helpdesk/tickets/#{id}.json", :headers => auth
    end
    assert_response :no_content
    assert_nil HelpdeskTicketInfo.find_by(:issue_id => id)

    # als geloescht bestaetigen
    get "/helpdesk/tickets/#{id}.json", :headers => auth
    assert_response :not_found
  end

  # --- Projekt-Einstellungen: anzeigen + (partiell) aktualisieren -----------

  def test_project_settings_show_and_update
    # anzeigen (Singleton, wird bei Bedarf initialisiert)
    get "/projects/#{@project.id}/helpdesk/settings.json", :headers => auth
    assert_response :success
    body = ActiveSupport::JSON.decode(@response.body)['helpdesk_project_setting']
    assert_equal @project.id, body['project']['id']
    assert body.key?('sla_priorities')

    # partielles Update: SLA aktivieren + Zielzeiten
    put "/projects/#{@project.id}/helpdesk/settings.json",
        :params => { :helpdesk_project_setting => {
          :sla_enabled => true, :sla_reaction_minutes => 60, :sla_solution_minutes => 480,
          :sla_work_days => [1, 2, 3, 4, 5]
        } }, :headers => auth
    assert_response :success

    setting = HelpdeskProjectSetting.for_project(@project)
    assert setting.sla_enabled?
    assert_equal 60, setting.sla_reaction_minutes
    assert_equal '1,2,3,4,5', setting.sla_work_days
    assert_not_nil setting.sla_enabled_at, 'activation timestamp stamped'

    # Schreiben ohne manage_helpdesk -> 403
    Role.find(1).remove_permission!(:manage_helpdesk)
    put "/projects/#{@project.id}/helpdesk/settings.json",
        :params => { :helpdesk_project_setting => { :sla_reaction_minutes => 30 } }, :headers => auth
    assert_response :forbidden
  end
end
