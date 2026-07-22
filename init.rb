# Redmine Expert Helpdesk Plugin
#
# E-Mail-zu-Ticket-Plugin mit Microsoft-Graph-Anbindung (O365, OAuth Client Credentials).
# Pro Projekt koennen Postfaecher konfiguriert werden, deren Mails als Tickets
# bzw. Ticket-Antworten verarbeitet werden.

require File.expand_path('../lib/redmine_expert_helpdesk/graph_client', __FILE__)
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
require File.expand_path('../lib/redmine_expert_helpdesk/api_serializers', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/patches/projects_helper_patch', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/patches/project_patch', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/patches/issue_patch', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/patches/issue_query_patch', __FILE__)
require File.expand_path('../lib/redmine_expert_helpdesk/patches/queries_helper_patch', __FILE__)

Redmine::Plugin.register :redmine_expert_helpdesk do
  name 'Redmine expert Helpdesk'
  author 'Dennis Buehring'
  description 'Helpdesk plugin: email-to-ticket via Microsoft Graph (O365 OAuth), autoresponder, customer replies, and rules engine'
  version '0.1.0'
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
             'kb_min_results'     => '1'
           }

  project_module :helpdesk do
    permission :manage_helpdesk, {
      :helpdesk_mailboxes => [:new, :create, :edit, :update, :destroy],
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
end

# Patches direkt anwenden: Redmine fuehrt init.rb innerhalb eines
# to_prepare-Callbacks aus (PluginLoader#run_initializer) und laedt es im
# Dev-Modus bei jedem Reload erneut. Eigene to_prepare-Registrierungen aus
# init.rb heraus wuerden in Produktion nie ausgefuehrt, da die Callbacks zu
# diesem Zeitpunkt bereits in den Reloader kopiert wurden.
unless ProjectsHelper.ancestors.include?(RedmineExpertHelpdesk::Patches::ProjectsHelperPatch)
  ProjectsHelper.prepend(RedmineExpertHelpdesk::Patches::ProjectsHelperPatch)
end
unless Project.included_modules.include?(RedmineExpertHelpdesk::Patches::ProjectPatch)
  Project.include(RedmineExpertHelpdesk::Patches::ProjectPatch)
end
unless Issue.included_modules.include?(RedmineExpertHelpdesk::Patches::IssuePatch)
  Issue.include(RedmineExpertHelpdesk::Patches::IssuePatch)
end
unless IssueQuery.ancestors.include?(RedmineExpertHelpdesk::Patches::IssueQueryPatch)
  IssueQuery.prepend(RedmineExpertHelpdesk::Patches::IssueQueryPatch)
end
unless QueriesHelper.ancestors.include?(RedmineExpertHelpdesk::Patches::QueriesHelperPatch)
  QueriesHelper.prepend(RedmineExpertHelpdesk::Patches::QueriesHelperPatch)
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
