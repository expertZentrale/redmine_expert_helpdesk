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
    def mailbox_ref(api, mailbox)
      return if mailbox.nil?

      api.mailbox(:id => mailbox.id, :address => mailbox.mailbox_address)
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
