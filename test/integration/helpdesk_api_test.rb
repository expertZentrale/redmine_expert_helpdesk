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
    assert_equal false, body['info_request_opt_out']

    # "never ask this customer for more information" is writable over the API too,
    # so a monitoring integration can flag its own sender when it registers it.
    put "/helpdesk/contacts/#{id}.json",
        :params => { :helpdesk_contact => { :info_request_opt_out => '1' } }, :headers => auth
    assert_response :no_content
    assert_equal true, HelpdeskContact.find(id).info_request_opt_out?

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
    assert body.key?('default_assigned_to_id')

    # partielles Update: SLA aktivieren + Zielzeiten
    put "/projects/#{@project.id}/helpdesk/settings.json",
        :params => { :helpdesk_project_setting => {
          :sla_enabled => true, :sla_reaction_minutes => 60, :sla_solution_minutes => 480,
          :sla_work_days => [1, 2, 3, 4, 5], :default_assigned_to_id => 2
        } }, :headers => auth
    assert_response :success

    setting = HelpdeskProjectSetting.for_project(@project)
    assert setting.sla_enabled?
    assert_equal 60, setting.sla_reaction_minutes
    assert_equal '1,2,3,4,5', setting.sla_work_days
    assert_equal 2, setting.default_assigned_to_id
    assert_not_nil setting.sla_enabled_at, 'activation timestamp stamped'

    # Schreiben ohne manage_helpdesk -> 403
    Role.find(1).remove_permission!(:manage_helpdesk)
    put "/projects/#{@project.id}/helpdesk/settings.json",
        :params => { :helpdesk_project_setting => { :sla_reaction_minutes => 30 } }, :headers => auth
    assert_response :forbidden
  end

  # KI-/Wissensbasis-Felder sind erst mit dem Mailbox-API nachgezogen worden.
  def test_project_settings_ai_and_kb_round_trip
    put "/projects/#{@project.id}/helpdesk/settings.json",
        :params => { :helpdesk_project_setting => {
          :ai_summary_enabled => true, :ai_summary_scope => 'initial_and_replies',
          :ai_prompt_mode => 'override', :ai_prompt => 'Fasse zusammen.',
          :ai_include_journal => true, :kb_ingest_mode => 'auto',
          :kb_proposal_display => 'sidebar'
        } }, :headers => auth
    assert_response :success

    setting = HelpdeskProjectSetting.for_project(@project)
    assert setting.ai_summary_enabled?
    assert_equal 'initial_and_replies', setting.ai_summary_scope
    assert_equal 'override', setting.ai_prompt_mode
    assert_equal 'Fasse zusammen.', setting.ai_prompt
    assert setting.ai_include_journal?
    assert_equal 'auto', setting.kb_ingest_mode
    assert_equal 'sidebar', setting.kb_proposal_display

    get "/projects/#{@project.id}/helpdesk/settings.json", :headers => auth
    body = ActiveSupport::JSON.decode(@response.body)['helpdesk_project_setting']
    assert_equal true, body['ai_summary_enabled']
    assert_equal 'auto', body['kb_ingest_mode']
  end

  # The info_request_* fields were documented as writable but silently ignored
  # (issue #17). Every documented key must round-trip.
  def test_project_settings_info_request_round_trip
    open_status = IssueStatus.where(:is_closed => false).first
    put "/projects/#{@project.id}/helpdesk/settings.json",
        :params => { :helpdesk_project_setting => {
          :info_request_mode => 'heuristic', :info_request_min_chars => 60,
          :info_request_min_words => 5, :info_request_require_attachment => true,
          :info_request_min_attachment_kb => 20, :info_request_keywords => "drucker\nkasse",
          :info_request_sender_blacklist => '@monitoring.local', :info_request_threshold => 2,
          :info_request_ai_prompt_mode => 'extend', :info_request_ai_prompt => 'Sei streng.',
          :info_request_subject => 'Rueckfrage zu #{{issue.id}}', :info_request_body => 'Bitte: {{missing_info}}',
          :info_request_note_visibility => 'private', :info_request_status_id => open_status.id
        } }, :headers => auth
    assert_response :success

    s = HelpdeskProjectSetting.for_project(@project)
    assert_equal 'heuristic', s.info_request_mode
    assert_equal 60, s.info_request_min_chars
    assert_equal 5, s.info_request_min_words
    assert s.info_request_require_attachment?
    assert_equal 20, s.info_request_min_attachment_kb
    assert_equal "drucker\nkasse", s.info_request_keywords
    assert_equal '@monitoring.local', s.info_request_sender_blacklist
    assert_equal 2, s.info_request_threshold
    assert_equal 'extend', s.info_request_ai_prompt_mode
    assert_equal 'Sei streng.', s.info_request_ai_prompt
    assert_equal 'Rueckfrage zu #{{issue.id}}', s.info_request_subject
    assert_equal 'Bitte: {{missing_info}}', s.info_request_body
    assert_equal 'private', s.info_request_note_visibility
    assert_equal open_status.id, s.info_request_status_id

    body = ActiveSupport::JSON.decode(@response.body)['helpdesk_project_setting']
    assert_equal 60, body['info_request_min_chars']
    assert_equal open_status.id, body['info_request_status_id']

    # Partial: an unrelated update leaves the fields alone; null clears a text field.
    put "/projects/#{@project.id}/helpdesk/settings.json",
        :params => { :helpdesk_project_setting => { :info_request_keywords => nil, :sla_enabled => false } },
        :headers => auth
    assert_response :success
    s.reload
    assert_nil s.info_request_keywords
    assert_equal 60, s.info_request_min_chars
  end

  def test_project_settings_info_request_rejects_invalid_values
    closed = IssueStatus.where(:is_closed => true).first
    [
      { :info_request_mode => 'sometimes' },
      { :info_request_threshold => 0 },
      { :info_request_min_chars => -1 },
      { :info_request_note_visibility => 'secret' },
      { :info_request_status_id => closed.id },
      { :info_request_status_id => 999_999 }
    ].each do |bad|
      put "/projects/#{@project.id}/helpdesk/settings.json",
          :params => { :helpdesk_project_setting => bad }, :headers => auth
      assert_response :unprocessable_entity, "expected 422 for #{bad.inspect}"
    end
    assert_nil HelpdeskProjectSetting.for_project(@project).info_request_status_id

    # null is documented for the threshold and means "default", not 0.
    put "/projects/#{@project.id}/helpdesk/settings.json",
        :params => { :helpdesk_project_setting => { :info_request_threshold => nil } }, :headers => auth
    assert_response :success
    assert_nil HelpdeskProjectSetting.for_project(@project).info_request_threshold
  end

  # --- Postfaecher ---------------------------------------------------------

  def mailbox_params(extra = {})
    { :mailbox_address => 'api-mailbox@example.com', :provider => 'imap',
      :imap_host => 'imap.example.com', :smtp_host => 'smtp.example.com',
      :credentials_source => 'mailbox', :auth_method => 'password',
      :mail_password => 's3cret' }.merge(extra)
  end

  def create_mailbox!(extra = {})
    post "/projects/#{@project.id}/helpdesk/mailboxes.json",
         :params => { :helpdesk_mailbox => mailbox_params(extra) }, :headers => auth
    assert_response :created
    ActiveSupport::JSON.decode(@response.body)['helpdesk_mailbox']
  end

  def test_mailboxes_index_requires_authentication
    get "/projects/#{@project.id}/helpdesk/mailboxes.json"
    assert_response :unauthorized
  end

  # Lesen erfordert manage_helpdesk (nicht view_helpdesk_info): die Konfiguration
  # enthaelt Hosts, Benutzernamen und OAuth-Client-IDs.
  def test_mailboxes_index_forbidden_without_manage_permission
    Role.find(1).remove_permission!(:manage_helpdesk)
    get "/projects/#{@project.id}/helpdesk/mailboxes.json", :headers => auth
    assert_response :forbidden
  end

  def test_mailboxes_index_forbidden_without_module
    @project.disable_module!(:helpdesk)
    get "/projects/#{@project.id}/helpdesk/mailboxes.json", :headers => auth
    assert_response :forbidden
  end

  def test_mailbox_lifecycle
    mailbox = nil
    assert_difference 'HelpdeskMailbox.count', 1 do
      mailbox = create_mailbox!
    end
    id = mailbox['id']
    assert_equal 'imap', mailbox['provider']
    assert_equal @project.id, mailbox['project']['id']

    # anzeigen
    get "/helpdesk/mailboxes/#{id}.json", :headers => auth
    assert_response :success
    body = ActiveSupport::JSON.decode(@response.body)['helpdesk_mailbox']
    assert_equal 'imap.example.com', body['imap_host']
    assert_includes body['available_reply_transports'], 'smtp'

    # aendern
    put "/helpdesk/mailboxes/#{id}.json",
        :params => { :helpdesk_mailbox => { :imap_port => 143, :imap_security => 'starttls' } },
        :headers => auth
    assert_response :no_content
    assert_equal 143, HelpdeskMailbox.find(id).imap_port

    # loeschen + als geloescht bestaetigen
    assert_difference 'HelpdeskMailbox.count', -1 do
      delete "/helpdesk/mailboxes/#{id}.json", :headers => auth
    end
    assert_response :no_content
    get "/helpdesk/mailboxes/#{id}.json", :headers => auth
    assert_response :not_found
  end

  # Der wichtigste Vertrag des Mailbox-APIs: Secrets gehen rein, nie wieder raus.
  def test_mailbox_never_serializes_secrets
    mailbox = create_mailbox!
    assert_equal true, mailbox['mail_password_set']

    get "/helpdesk/mailboxes/#{mailbox['id']}.json", :headers => auth
    assert_no_match(/s3cret/, @response.body)
    assert_no_match(/enc:v1:/, @response.body)
    body = ActiveSupport::JSON.decode(@response.body)['helpdesk_mailbox']
    %w[mail_password oauth_client_secret oauth_sa_key oauth_refresh_token
       mail_password_enc oauth_client_secret_enc oauth_sa_key_enc
       oauth_refresh_token_enc].each do |key|
      assert_not body.key?(key), "#{key} must not be serialized"
    end
  end

  # Leer/weggelassen behaelt das Secret, "-" loescht es (HelpdeskMailbox#assign_secret).
  def test_mailbox_secret_write_semantics
    id = create_mailbox!['id']

    put "/helpdesk/mailboxes/#{id}.json",
        :params => { :helpdesk_mailbox => { :imap_username => 'svc' } }, :headers => auth
    assert_response :no_content
    assert_equal 's3cret', HelpdeskMailbox.find(id).mail_password

    put "/helpdesk/mailboxes/#{id}.json",
        :params => { :helpdesk_mailbox => { :mail_password => HelpdeskMailbox::CLEAR_SECRET } },
        :headers => auth
    assert_response :no_content
    assert_nil HelpdeskMailbox.find(id).mail_password_enc
  end

  def test_mailbox_create_validation_error
    assert_no_difference 'HelpdeskMailbox.count' do
      post "/projects/#{@project.id}/helpdesk/mailboxes.json",
           :params => { :helpdesk_mailbox => mailbox_params(:provider => 'pop3') },
           :headers => auth
    end
    assert_response :unprocessable_entity
  end

  # Ein leerer imap_host ist KEIN Validierungsfehler: before_validation
  # apply_preset! fuellt leere Verbindungsfelder aus Preset und globalen
  # Vorgaben, bevor die presence-Pruefung laeuft. Das API dokumentiert das
  # (minimales Payload genuegt) - hier festgenagelt, damit es so bleibt.
  def test_mailbox_create_fills_blank_connection_fields_from_preset
    mailbox = create_mailbox!(:imap_host => '')
    assert mailbox['imap_host'].present?, 'imap_host filled from preset defaults'
  end

  # project_id ist bewusst kein safe_attribute - das Projekt kommt aus der Route.
  def test_mailbox_create_ignores_project_id_in_payload
    mailbox = create_mailbox!(:project_id => 2)
    assert_equal @project.id, HelpdeskMailbox.find(mailbox['id']).project_id
  end
end
