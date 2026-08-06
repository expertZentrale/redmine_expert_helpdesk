# Redmine Expert Helpdesk Plugin
#
# Copyright (C) 2026 Dennis Buehring
#
# This program is free software; you can redistribute it and/or modify it under
# the terms of the GNU General Public License as published by the Free Software
# Foundation; either version 2 of the License, or (at your option) any later
# version. See LICENSE for the full text.
#
# E-Mail-zu-Ticket-Plugin mit Microsoft-Graph-Anbindung (O365, OAuth Client Credentials).
# Pro Projekt koennen Postfaecher konfiguriert werden, deren Mails als Tickets
# bzw. Ticket-Antworten verarbeitet werden.

require File.expand_path('../lib/redmine_expert_helpdesk/secret_box', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/provider_presets', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/xoauth2', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/mail_logger', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/mail_provider', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/mailbox_credentials', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/oauth_token_provider', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/graph_client', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/graph_provider', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/imap_client', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/smtp_sender', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/imap_provider', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/mailbox_folders', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/ai_logger', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/ai_client', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/knowledge_store', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/knowledge_extractor', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/template_renderer', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/mail_processor', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/init_mailer', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/hooks', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/phishtank_sync', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/phishing_database_sync', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/phishing_feeds', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/phishing_scanner', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/legacy_contacts_import', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/business_hours', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/sla', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/sla_breach_check', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/sla_statistics', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/ai_usage_statistics', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/api_serializers', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/patches/projects_helper_patch', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/patches/project_patch', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/patches/issue_patch', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/patches/issue_query_patch', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/patches/queries_helper_patch', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/patches/issue_css_classes_patch', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/patches/journal_patch', __FILE__)

Redmine::Plugin.register :redmine_expert_helpdesk do
  name 'Redmine expert Helpdesk'
  author 'Dennis Buehring'
  description 'Helpdesk plugin: email-to-ticket via Microsoft Graph or IMAP/SMTP, autoresponder, customer replies, SLA, and rules engine'
  version '0.2.3'
  requires_redmine :version_or_higher => '5.0'
  url 'https://github.com/expertZentrale/redmine_expert_helpdesk'

  # Zentrale App-Registrierung (Azure AD / Entra ID) und API-Key fuer den Fetch-Endpunkt
  settings :partial => 'settings/helpdesk_settings',
           :default => {
             'tenant_id'                => '',
             'client_id'                => '',
             'client_secret'            => '',
             'fetch_api_key'            => '',
             'sla_api_key'              => '',
             # Defaults for mailboxes with credentials_source = 'global'. The
             # application registration itself is tenant_id/client_id/client_secret
             # above - it is shared with the Graph provider, never duplicated here.
             'default_oauth_preset'        => 'microsoft',
             'default_oauth_grant'         => 'client_credentials',
             'default_oauth_authorize_url' => '',
             'default_oauth_token_url'     => '',
             'default_oauth_scope'         => '',
             'default_imap_host'     => '',
             'default_imap_port'     => '993',
             'default_imap_security' => 'ssl',
             'default_smtp_host'     => '',
             'default_smtp_port'     => '587',
             'default_smtp_security' => 'starttls',
             'awaiting_agent_enabled'   => '1',
             'contacts_per_page'        => '25',
             'contact_ticket_limit'     => '10',
             'phishtank_enabled'        => '0',
             'phishtank_app_key'        => '',
             'phishtank_feed_url'       => 'https://data.phishtank.com/data/{key}/online-valid.json.gz',
             'phishtank_interval_hours' => '6',
             'phishing_database_enabled'  => '0',
             'phishing_database_feed_url' => 'https://raw.githubusercontent.com/Phishing-Database/Phishing.Database/master/phishing-links-ACTIVE.txt',
             'global_footer'            => '',
             'ai_enabled'           => '0',
             'ai_provider'          => 'openai',
             'ai_api_key'           => '',
             'ai_endpoint'          => '',
             'ai_model'             => '',
             'ai_prompt'            => RedmineExpertHelpdesk::AiClient::DEFAULT_PROMPT,
             'ai_max_input_chars'   => '12000',
             'ai_min_input_chars'   => '200',
             'ai_log_level'         => RedmineExpertHelpdesk::AiLogger::DEFAULT_LEVEL,
             'ai_max_output_tokens' => '500',
             'ai_timeout'           => '60',
             'kb_enabled'         => '0',
             'kb_backend'         => 'qdrant',
             'kb_qdrant_url'      => '',
             'kb_qdrant_api_key'  => '',
             'kb_pg_url'          => '',
             'kb_embed_provider'  => 'openai',
             'kb_embed_model'     => 'text-embedding-3-small',
             'kb_embed_endpoint'  => '',
             'kb_embed_api_key'   => '',
             'kb_extract_prompt'  => RedmineExpertHelpdesk::KnowledgeExtractor::DEFAULT_PROMPT,
             'kb_top_k'           => '3',
             'kb_min_score'       => '0.5',
             'kb_min_results'     => '1',
             # Severity of the "mail sent" log line (failures are always errors).
             'mail_log_level'     => RedmineExpertHelpdesk::MailLogger::DEFAULT_LEVEL
           }

  project_module :helpdesk do
    permission :manage_helpdesk, {
      :helpdesk_mailboxes => [:new, :create, :edit, :update, :destroy,
                              :folders, :create_folder, :test_connection, :oauth_authorize],
      :helpdesk_oauth => [:authorize, :callback],
      :helpdesk_rules     => [:create, :destroy]
    }, :require => :member
    permission :fetch_helpdesk_mail, {
      :helpdesk_fetch => [:fetch]
    }, :require => :member
    permission :send_helpdesk_reply, {
      :helpdesk_replies  => [:create],
      :helpdesk_contacts => [:autocomplete],
      :helpdesk_init     => [:create]
    }, :require => :member
    permission :view_helpdesk_info, {}, :read => true
    permission :manage_helpdesk_contacts, {
      :helpdesk_contacts => [:index, :edit, :update, :destroy, :autocomplete]
    }, :require => :member
    permission :view_helpdesk_sla_statistics, {
      :helpdesk_sla_statistics => [:index]
    }, :read => true
  end

  # Globale Berechtigung fuer die KI-Statistik (Kostenrisiko der KI-Funktionen).
  # Ausserhalb des project_module deklariert (:global => true), damit sie einmalig
  # einer Rolle (z. B. "ai-admin") gewaehrt werden kann und dann projektuebergreifend
  # gilt – ohne Projektmitgliedschaft.
  permission :view_helpdesk_ai_statistics, {
    :helpdesk_ai_statistics => [:index]
  }, :global => true

  menu :project_menu, :helpdesk_contacts,
       { :controller => 'helpdesk_contacts', :action => 'index' },
       :caption  => :label_helpdesk_customers,
       :after    => :issues,
       :param    => :project_id,
       :if       => Proc.new { |p| p.module_enabled?(:helpdesk) }

  # SLA-Statistik-Reiter nur bei aktivem SLA im Projekt
  menu :project_menu, :helpdesk_sla_statistics,
       { :controller => 'helpdesk_sla_statistics', :action => 'index' },
       :caption  => :label_helpdesk_sla_statistics,
       :after    => :helpdesk_contacts,
       :param    => :project_id,
       :if       => Proc.new { |p|
         p.module_enabled?(:helpdesk) &&
           HelpdeskProjectSetting.for_project(p).sla_enabled?
       }

  # KI-Statistik-Reiter: sichtbar bei aktivem Helpdesk-Modul und globaler
  # Berechtigung view_helpdesk_ai_statistics (Rolle "ai-admin").
  menu :project_menu, :helpdesk_ai_statistics,
       { :controller => 'helpdesk_ai_statistics', :action => 'index' },
       :caption  => :label_helpdesk_ai_statistics,
       :after    => :helpdesk_sla_statistics,
       :param    => :project_id,
       :if       => Proc.new { |p|
         p.module_enabled?(:helpdesk) &&
           User.current.allowed_to?(:view_helpdesk_ai_statistics, nil, :global => true)
       }

  # Direkter Eintrag im Administrationsmenue (Sidebar + Admin-Uebersicht),
  # der ohne Umweg ueber "Plugins > Konfigurieren" direkt auf die
  # Plugin-Einstellungen verlinkt. Icon versionsabhaengig:
  #  - Redmine 6/7: SVG-Sprite-Icon aus dem Plugin-Sprite (assets/images/icons.svg,
  #    Symbol `icon--helpdesk`) ueber :icon + :plugin (render_single_menu_node ruft
  #    sprite_icon(item.icon, plugin: item.plugin)).
  #  - Redmine 5: die alten SVG-Sprites/`:icon` gibt es noch nicht -> altes
  #    CSS-Sprite-Icon ueber die `icon icon-*`-Klasse am Link.
  admin_menu_options = { :caption => :label_expert_helpdesk }
  if Redmine::VERSION::MAJOR >= 6
    admin_menu_options[:icon]   = 'helpdesk'
    admin_menu_options[:plugin] = 'redmine_expert_helpdesk'
    # `icon`-Klasse noetig, damit das SVG die blaue currentColor-Strichfarbe der
    # anderen Admin-Menue-Icons erbt (ohne sie bleibt es im .icon-svg-Standardgrau).
    admin_menu_options[:html]   = { :class => 'icon' }
  else
    admin_menu_options[:html] = { :class => 'icon icon-email' }
  end
  menu :admin_menu, :redmine_expert_helpdesk,
       { :controller => 'settings', :action => 'plugin', :id => 'redmine_expert_helpdesk' },
       admin_menu_options
end

# Patches direkt anwenden: Redmine fuehrt init.rb innerhalb eines
# to_prepare-Callbacks aus (PluginLoader#run_initializer) und laedt es im
# Dev-Modus bei jedem Reload erneut. Eigene to_prepare-Registrierungen aus
# init.rb heraus wuerden in Produktion nie ausgefuehrt, da die Callbacks zu
# diesem Zeitpunkt bereits in den Reloader kopiert wurden.
# project_settings_tabs per UnboundMethod-Capture patchen (nicht prepend/super),
# damit der Helpdesk-Reiter mit alias_method_chain-Plugins koexistiert
# (z. B. RedmineUP redmine_contacts_helpdesk). Siehe projects_helper_patch.rb.
RedmineExpertHelpdesk::Patches::ProjectsHelperPatch.apply!(ProjectsHelper)
unless Project.included_modules.include?(RedmineExpertHelpdesk::Patches::ProjectPatch)
  Project.include(RedmineExpertHelpdesk::Patches::ProjectPatch)
end
unless Issue.included_modules.include?(RedmineExpertHelpdesk::Patches::IssuePatch)
  Issue.include(RedmineExpertHelpdesk::Patches::IssuePatch)
end
unless IssueQuery.ancestors.include?(RedmineExpertHelpdesk::Patches::IssueQueryPatch)
  IssueQuery.prepend(RedmineExpertHelpdesk::Patches::IssueQueryPatch)
end
# column_content ebenfalls per UnboundMethod-Capture (nicht prepend/super), damit
# die SLA-Chip-Spalten mit alias_method_chain-Plugins koexistieren
# (z. B. RedmineUP redmine_contacts_helpdesk). Siehe queries_helper_patch.rb.
RedmineExpertHelpdesk::Patches::QueriesHelperPatch.apply!(QueriesHelper)

# css_classes ebenfalls per UnboundMethod-Capture (siehe issue_css_classes_patch.rb):
# IssuePatch wird per include eingebunden und kann die Methode nicht ueberschreiben.
RedmineExpertHelpdesk::Patches::IssueCssClassesPatch.apply!(Issue)

unless Journal.included_modules.include?(RedmineExpertHelpdesk::Patches::JournalPatch)
  Journal.include(RedmineExpertHelpdesk::Patches::JournalPatch)
end
# hd_icon_label global verfuegbar machen: Redmine setzt include_all_helpers = false,
# daher werden Plugin-Helfer nicht automatisch in Kern-Views eingebunden.
# ApplicationHelper ist in allen Views verfuegbar.
unless ApplicationHelper.included_modules.include?(HelpdeskIconsHelper)
  ApplicationHelper.include(HelpdeskIconsHelper)
end

# Aktivitaets-Feed: eingehende, ausgehende und initiale Helpdesk-Nachrichten registrieren.
# Ab Redmine 6 muss das Plugin angegeben werden, damit der Feed die Richtungs-Icons aus
# dem Plugin-Sprite (assets/icons.svg) laedt: activity_event_type_icon -> sprite_icon(
# 'helpdesk-message-in', plugin: 'redmine_expert_helpdesk'). Ohne :plugin liefert
# Redmine::Activity.plugin_name nil, das Icon wird im Kern-Sprite gesucht (nicht vorhanden).
helpdesk_activity_options = { :class_name => 'HelpdeskMessage', :default => true }
helpdesk_activity_options[:plugin] = 'redmine_expert_helpdesk' if Redmine::VERSION::MAJOR >= 6
Redmine::Activity.register :helpdesk_messages, helpdesk_activity_options
