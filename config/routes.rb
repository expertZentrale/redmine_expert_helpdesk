# Routen des Expert-Helpdesk-Plugins
RedmineApp::Application.routes.draw do
  # Manueller Mailabruf pro Projekt (Button in den Projekteinstellungen)
  post 'projects/:project_id/helpdesk/fetch', :to => 'helpdesk_fetch#fetch', :as => 'project_helpdesk_fetch'

  # Globaler Abruf aller aktiven Postfaecher (z. B. via curl/CronJob), gesichert per API-Key
  match 'helpdesk/fetch_all', :to => 'helpdesk_fetch#fetch_all', :via => [:get, :post], :as => 'helpdesk_fetch_all'

  # SLA-Pruefung fuer externen CronJob, gesichert per eigenem API-Key
  match 'helpdesk/sla_check', :to => 'helpdesk_fetch#sla_check', :via => [:get, :post], :as => 'helpdesk_sla_check'

  # Manueller PhishTank-Sync (Button in den Plugin-Einstellungen, nur Admins)
  post 'helpdesk/phishtank_sync', :to => 'helpdesk_phishtank#sync', :as => 'helpdesk_phishtank_sync'

  # Import der Altdaten aus redmine_contacts (Button in den Plugin-Einstellungen, nur Admins)
  get  'helpdesk/legacy_import/select', :to => 'helpdesk_legacy_import#new', :as => 'helpdesk_legacy_import_select'
  post 'helpdesk/legacy_import', :to => 'helpdesk_legacy_import#import', :as => 'helpdesk_legacy_import'
  # EML attachments: project selection, then repair (onto the issue) or restore (back to RedmineUP)
  get  'helpdesk/legacy_attachments/select', :to => 'helpdesk_legacy_import#attachments',
       :as => 'helpdesk_legacy_attachments_select'
  post 'helpdesk/legacy_fix_attachments', :to => 'helpdesk_legacy_import#fix_attachments', :as => 'helpdesk_legacy_fix_attachments'
  # Status page of a background import or repair run, and its polling endpoint.
  # The poll is JSON without a .json format: Redmine ignores the session on
  # json/xml requests (it treats them as REST API calls), so the browser would get 403.
  get  'helpdesk/legacy_import/runs/:id', :to => 'helpdesk_legacy_import#show', :as => 'helpdesk_legacy_import_run',
       :constraints => { :id => /\d+/ }
  get  'helpdesk/legacy_import/runs/:id/status', :to => 'helpdesk_legacy_import#poll',
       :as => 'helpdesk_legacy_import_run_status', :constraints => { :id => /\d+/ }

  # OAuth2-Consent (authorization_code) fuer IMAP/SMTP-Postfaecher.
  # Die Callback-URL ist fest, weil Identity Provider nur exakt registrierte
  # Redirect-URIs akzeptieren; das Postfach steckt im signierten state-Parameter.
  get 'helpdesk/oauth/authorize', :to => 'expert_helpdesk_oauth#authorize', :as => 'expert_helpdesk_oauth_authorize'
  get 'helpdesk/oauth/callback',  :to => 'expert_helpdesk_oauth#callback',  :as => 'expert_helpdesk_oauth_callback'

  # Postfach-Konfiguration je Projekt
  scope 'projects/:project_id' do
    resources :helpdesk_mailboxes, :except => [:index, :show] do
      collection do
        # POST, weil der Formularzustand (inkl. Provider-Auswahl) mitgeschickt wird;
        # GET bleibt aus Kompatibilitaetsgruenden erhalten.
        get  :folders
        post :folders
        post :create_folder
        post :test_connection
      end
      member do
        get :oauth_authorize
      end
    end

    # Kundenliste und -bearbeitung je Projekt
    resources :helpdesk_contacts, :only => [:index, :edit, :update, :destroy] do
      collection do
        get :autocomplete
      end
      member do
        # One-click "never ask this customer" from the ticket header bar.
        post :toggle_info_request
      end
    end

    # Projekt-spezifische Helpdesk-Einstellungen (Antwort-Standardwerte)
    resource :helpdesk_project_setting, :only => [:update]

    # Knowledge base tab: list, verify and correct RAG entries (view/edit/manage_helpdesk_kb)
    resources :helpdesk_kb_entries do
      member do
        post :approve
        post :reject
      end
      collection do
        post :reindex
      end
    end

    # Answer templates of this project (tab "expert Helpdesk")
    resources :helpdesk_reply_templates, :except => [:show]

    # Blacklist of attachment contents (list and removal live in the project
    # settings; entries are added from the ticket page, see below)
    resources :helpdesk_attachment_blacklists, :only => [:destroy]

    # SLA-Statistik je Projekt (nur sichtbar/erreichbar bei aktivem SLA)
    resources :helpdesk_sla_statistics, :only => [:index]

    # Ticket statistics per project (member permission view_helpdesk_ticket_statistics)
    resources :helpdesk_ticket_statistics, :only => [:index]

    # KI-Statistik je Projekt (nur mit globaler Berechtigung view_helpdesk_ai_statistics)
    resources :helpdesk_ai_statistics, :only => [:index]

    # REST-API (projektbezogen: Liste/Anlegen), JSON/XML via .api.rsb
    resources :helpdesk_contacts_api, :path => 'helpdesk/contacts',
              :controller => 'helpdesk_contacts_api', :only => [:index, :create]
    resources :helpdesk_tickets_api, :path => 'helpdesk/tickets',
              :controller => 'helpdesk_tickets_api', :only => [:index, :create]
    resources :helpdesk_mailboxes_api, :path => 'helpdesk/mailboxes',
              :controller => 'helpdesk_mailboxes_api', :only => [:index, :create]
    # Projekt-Helpdesk-Einstellungen (Singleton je Projekt)
    resource :helpdesk_project_setting_api, :path => 'helpdesk/settings',
             :controller => 'helpdesk_project_settings_api', :only => [:show, :update]
  end

  # REST-API (global per ID: Anzeigen/Aendern/Loeschen)
  resources :helpdesk_contacts_api, :path => 'helpdesk/contacts',
            :controller => 'helpdesk_contacts_api', :only => [:show, :update, :destroy]
  resources :helpdesk_tickets_api, :path => 'helpdesk/tickets',
            :controller => 'helpdesk_tickets_api', :only => [:show, :update, :destroy]
  resources :helpdesk_mailboxes_api, :path => 'helpdesk/mailboxes',
            :controller => 'helpdesk_mailboxes_api', :only => [:show, :update, :destroy] do
    member do
      post :test_connection
    end
  end

  # Regeln je Postfach
  resources :helpdesk_mailboxes, :only => [] do
    resources :helpdesk_rules, :only => [:create, :destroy]
  end

  # Global answer templates (Administration -> Plugins). Own route name,
  # because the project-scoped templates above serve the same resource.
  resources :helpdesk_reply_templates, :except => [:show],
            :as => :global_helpdesk_reply_templates

  # Antwort an den Kunden aus dem Ticket heraus
  post 'issues/:issue_id/helpdesk_reply', :to => 'helpdesk_replies#create', :as => 'issue_helpdesk_reply'

  # Blacklisting an attachment's content from the ticket page. Keyed by the
  # attachment, not by a project: the project is the ticket's, so it cannot be
  # aimed at one the agent does not manage.
  # Under /helpdesk, not under /attachments: plugin routes are drawn after the core
  # ones, and core's "attachments/:id/:filename" (filename matches /.*/ ) would
  # swallow any GET below /attachments/<id>/ before it reaches us.
  #
  # Own route names as well, because the project-scoped resources above already
  # claim helpdesk_attachment_blacklist_path for their member routes.
  post 'helpdesk/attachments/:attachment_id/blacklist',
       :to => 'helpdesk_attachment_blacklists#create', :as => 'blacklist_helpdesk_attachment'
  get  'helpdesk/attachments/:attachment_id/blacklist/preview',
       :to => 'helpdesk_attachment_blacklists#preview', :as => 'blacklist_helpdesk_attachment_preview'

  # Quotes and answer templates for the note field (toolbar of the edit form)
  post 'issues/:issue_id/helpdesk_note_content', :to => 'helpdesk_note_content#create',
       :as => 'issue_helpdesk_note_content'

  # KI-Zusammenfassung manuell (neu) erzeugen (Button in der Ticket-Seitenleiste)
  post 'issues/:issue_id/helpdesk_ai_summary', :to => 'helpdesk_ai#regenerate', :as => 'issue_helpdesk_regenerate_ai'

  # Wissensbasis: Ticket manuell aufnehmen / pending-Eintrag freigeben
  post 'issues/:issue_id/helpdesk_kb_ingest',  :to => 'helpdesk_knowledge#ingest',  :as => 'issue_helpdesk_kb_ingest'
  post 'issues/:issue_id/helpdesk_kb_approve', :to => 'helpdesk_knowledge#approve', :as => 'issue_helpdesk_kb_approve'

  # Kontakt manuell zuordnen / initiale Mail senden (bestehende Tickets)
  scope 'projects/:project_id' do
    post 'issues/:issue_id/helpdesk_init', :to => 'helpdesk_init#create', :as => 'issue_helpdesk_init'
  end
end
