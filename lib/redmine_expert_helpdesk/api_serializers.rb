# Gemeinsame Serialisierer fuer die REST-API. Schreiben ein Objekt auf den
# Redmine-`api`-Builder (aus den .api.rsb-Templates), damit JSON und XML aus
# einer Quelle erzeugt werden. Reine Hilfsfunktionen ohne Rendering-Annahmen.
module RedmineExpertHelpdesk
  module ApiSerializers
    module_function

    # Kunde/Kontakt (Helpdesk).
    def contact(api, c)
      return if c.nil?

      api.helpdesk_contact do
        api.id      c.id
        api.email   c.email
        api.name    c.name
        api.company c.company
        api.phone   c.phone
        api.notes   c.notes
        api.project(:id => c.project_id) if c.project_id
        api.created_on c.created_at
        api.updated_on c.updated_at
      end
    end

    # Kompakte Kontakt-Referenz (in Ticket eingebettet).
    def contact_ref(api, c)
      return if c.nil?

      api.contact do
        api.id      c.id
        api.email   c.email
        api.name    c.display_name
        api.company c.company
        api.phone   c.phone
      end
    end

    # Ursprungspostfach-Referenz.
    # `provider` is part of the reference so a consumer can tell a Graph mailbox
    # from an IMAP one without fetching the full mailbox.
    def mailbox_ref(api, mailbox)
      return if mailbox.nil?

      api.mailbox(:id => mailbox.id, :address => mailbox.mailbox_address,
                  :provider => mailbox.provider)
    end

    # Full mailbox configuration.
    #
    # Secrets are NEVER serialized: the encrypted columns (mail_password_enc,
    # oauth_client_secret_enc, oauth_sa_key_enc, oauth_refresh_token_enc) and their
    # plaintext readers stay out of the API entirely. Clients get `*_set` booleans
    # instead, which is enough to render "configured / not configured".
    def mailbox(api, m)
      return if m.nil?

      api.helpdesk_mailbox do
        api.id      m.id
        api.project(:id => m.project_id, :name => m.project&.name)
        api.mailbox_address m.mailbox_address
        api.enabled m.enabled

        # --- Backend and outgoing route ---
        api.provider                   m.provider
        api.reply_transport            m.reply_transport
        api.outgoing_route             m.outgoing_route
        api.microsoft_hosted           m.microsoft_hosted?
        api.array :available_reply_transports do
          m.available_reply_transports.each { |t| api.transport t }
        end

        # --- Folders ---
        api.source_folder    m.source_folder
        api.processed_folder m.processed_folder
        api.skipped_folder   m.skipped_folder
        api.failed_folder    m.failed_folder
        api.sent_folder      m.sent_folder

        # --- Ticket defaults ---
        api.default_tracker_id   m.default_tracker_id
        api.default_priority_id  m.default_priority_id
        api.default_status_id    m.default_status_id
        api.unknown_user_mode    m.unknown_user_mode
        api.suppress_notifications m.suppress_notifications
        api.reopen_status_id     m.reopen_status_id
        api.reopen_max_age_days  m.reopen_max_age_days

        # --- Filters and replies ---
        api.allow_list m.allow_list
        api.deny_list  m.deny_list
        api.auto_reply_filter_enabled    m.auto_reply_filter_enabled
        api.auto_reply_sender_whitelist  m.auto_reply_sender_whitelist
        api.auto_reply_header_whitelist  m.auto_reply_header_whitelist
        api.autoresponder_enabled m.autoresponder_enabled
        api.autoresponder_subject m.autoresponder_subject
        api.autoresponder_body    m.autoresponder_body
        api.reply_header m.reply_header
        api.reply_footer m.reply_footer
        api.footer_mode  m.footer_mode

        # --- Connection (IMAP/SMTP) ---
        api.credentials_source m.credentials_source
        api.auth_method   m.auth_method
        api.imap_host     m.imap_host
        api.imap_port     m.imap_port
        api.imap_security m.imap_security
        api.imap_username m.imap_username
        api.imap_verify_ssl  m.imap_verify_ssl
        api.imap_unseen_only m.imap_unseen_only
        api.imap_timeout  m.imap_timeout
        api.smtp_host     m.smtp_host
        api.smtp_port     m.smtp_port
        api.smtp_security m.smtp_security
        api.smtp_username m.smtp_username
        api.smtp_verify_ssl m.smtp_verify_ssl

        # --- OAuth2 (non-secret parts only) ---
        api.oauth_preset    m.oauth_preset
        api.oauth_grant     m.oauth_grant
        api.oauth_tenant_id m.oauth_tenant_id
        api.oauth_client_id m.oauth_client_id
        api.oauth_authorize_url m.oauth_authorize_url
        api.oauth_token_url m.oauth_token_url
        api.oauth_scope     m.oauth_scope
        api.oauth_sa_email  m.oauth_sa_email
        api.oauth_connected m.oauth_connected?
        api.oauth_connected_at    m.oauth_connected_at
        api.oauth_token_expires_at m.oauth_token_expires_at

        # --- Secret presence (never the value itself) ---
        api.mail_password_set        m.mail_password_enc.present?
        api.oauth_client_secret_set  m.oauth_client_secret_enc.present?
        api.oauth_sa_key_set         m.oauth_sa_key_enc.present?
        api.oauth_refresh_token_set  m.oauth_refresh_token_enc.present?

        # --- Status ---
        api.last_fetched_at m.last_fetched_at
        api.last_error      m.last_error
        api.last_error_at   m.last_error_at
        api.created_on      m.created_at
        api.updated_on      m.updated_at
      end
    end

    # Ergebnis von MailProvider#test_connection.
    def connection_test(api, result)
      api.connection_test do
        api.ok      result[:ok] ? true : false
        api.message result[:message]
        if result[:folders]
          api.array :folders do
            result[:folders].each { |f| api.folder f.to_s }
          end
        end
        api.sent_folder result[:sent_folder] if result.key?(:sent_folder)
      end
    end

    # SLA-Zustand aus Sla.state_for ({ :reaction => clock|nil, :solution => clock|nil } | nil).
    def sla_state(api, state)
      return if state.nil?

      api.sla do
        clock(api, :reaction, state[:reaction])
        clock(api, :solution, state[:solution])
      end
    end

    def clock(api, name, data)
      return if data.nil?

      api.__send__(name) do
        api.status  data[:status]
        api.minutes data[:minutes]
        api.target  data[:target]
        api.due_at  data[:due_at] if data[:due_at]
      end
    end

    # Helpdesk-Ticket = Redmine-Issue + Zusatzdaten. detail=true fuegt
    # Beschreibung und Nachrichtenverlauf hinzu (Einzelansicht).
    def ticket(api, issue, info: nil, sla: nil, messages: [], detail: false)
      api.helpdesk_ticket do
        api.id issue.id
        api.project(:id => issue.project_id, :name => issue.project.name)
        api.tracker(:id => issue.tracker_id, :name => issue.tracker.name) if issue.tracker
        api.status(:id => issue.status_id, :name => issue.status.name) if issue.status
        api.priority(:id => issue.priority_id, :name => issue.priority.name) if issue.priority
        api.subject issue.subject
        api.description issue.description if detail
        api.author(:id => issue.author_id, :name => issue.author.name) if issue.author
        api.assigned_to(:id => issue.assigned_to_id, :name => issue.assigned_to.name) if issue.assigned_to
        api.done_ratio issue.done_ratio
        api.created_on issue.created_on
        api.updated_on issue.updated_on
        api.closed_on  issue.closed_on

        contact_ref(api, info && info.helpdesk_contact)
        mailbox_ref(api, info && info.helpdesk_mailbox)
        sla_state(api, sla)

        if detail
          api.array :messages do
            messages.each { |m| message(api, m) }
          end
        end
      end
    end

    # Projekt-Helpdesk-Einstellungen (Antwort-, Phishing-, SLA-Konfiguration) inkl.
    # der Prioritaets-Overrides (HelpdeskSlaPriority).
    def project_setting(api, s, priorities = [])
      api.helpdesk_project_setting do
        api.project(:id => s.project_id)
        api.send_reply_by_default   s.send_reply_by_default
        api.reply_subject_template  s.reply_subject_template
        api.reply_status_id         s.reply_status_id
        api.reply_assign_to_sender  s.reply_assign_to_sender
        api.default_assigned_to_id  s.default_assigned_to_id
        api.phishing_check_enabled  s.phishing_check_enabled
        api.phishing_action         s.phishing_action
        api.sla_enabled             s.sla_enabled
        api.sla_enabled_at          s.sla_enabled_at
        api.sla_reaction_minutes    s.sla_reaction_minutes
        api.sla_solution_minutes    s.sla_solution_minutes
        api.sla_work_days           s.sla_work_days   # CSV der ISO-Wochentage (1=Mo..7=So)
        api.sla_work_start          s.sla_work_start
        api.sla_work_end            s.sla_work_end
        api.sla_notify_enabled      s.sla_notify_enabled
        api.sla_notify_email        s.sla_notify_email
        api.sla_notify_user_id      s.sla_notify_user_id
        # KI-Zusammenfassung (opt-in je Projekt).
        api.ai_summary_enabled      s.ai_summary_enabled
        api.ai_summary_scope        s.ai_summary_scope
        api.ai_prompt_mode          s.ai_prompt_mode
        api.ai_prompt               s.ai_prompt
        api.ai_attach_metadata      s.ai_attach_metadata
        api.ai_attach_text          s.ai_attach_text
        api.ai_attach_images        s.ai_attach_images
        api.ai_min_image_kb         s.ai_min_image_kb
        api.ai_include_journal      s.ai_include_journal
        api.ai_include_private_notes s.ai_include_private_notes
        # Completeness check of incoming first mails (opt-in per project).
        api.info_request_mode               s.info_request_mode
        api.info_request_min_chars          s.info_request_min_chars
        api.info_request_min_words          s.info_request_min_words
        api.info_request_require_attachment s.info_request_require_attachment
        api.info_request_min_attachment_kb  s.info_request_min_attachment_kb
        api.info_request_keywords           s.info_request_keywords
        api.info_request_sender_blacklist   s.info_request_sender_blacklist
        api.info_request_threshold          s.info_request_threshold
        api.info_request_ai_prompt_mode     s.info_request_ai_prompt_mode
        api.info_request_ai_prompt          s.info_request_ai_prompt
        api.info_request_subject            s.info_request_subject
        api.info_request_body               s.info_request_body
        api.info_request_note_visibility    s.info_request_note_visibility
        api.info_request_status_id          s.info_request_status_id
        # Wissensbasis (RAG).
        api.kb_ingest_mode          s.kb_ingest_mode
        api.kb_proposal_display     s.kb_proposal_display
        api.array :sla_priorities do
          priorities.each do |p|
            api.sla_priority do
              api.priority_id      p.priority_id
              api.priority_name    (p.priority ? p.priority.name : nil)
              api.reaction_minutes p.reaction_minutes
              api.solution_minutes p.solution_minutes
            end
          end
        end
      end
    end

    # Einzelne Helpdesk-Nachricht (Nachrichtenverlauf eines Tickets).
    def message(api, m)
      api.message do
        api.id        m.id
        api.direction m.direction
        api.subject   m.subject
        api.sent_at   m.sent_at
        api.recipient_to  m.recipient_to
        api.recipient_cc  m.recipient_cc
        api.recipient_bcc m.recipient_bcc
        api.contact(:id => m.helpdesk_contact_id) if m.helpdesk_contact_id
        api.mailbox(:id => m.helpdesk_mailbox_id) if m.helpdesk_mailbox_id
        api.created_on m.created_at
      end
    end
  end
end
