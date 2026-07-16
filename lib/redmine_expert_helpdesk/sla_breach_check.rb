# Prueft offene Tickets in SLA-Projekten auf Ueberschreitungen und versendet
# einmalig eine Benachrichtigung (E-Mail-Adresse und/oder Projekt-User aus den
# Projekteinstellungen). Frischt zudem die vorberechneten SLA-Faelligkeiten aller
# SLA-Projekte auf (Backfill/Aktualisierung fuer die Grid-Spalten). Ausgeloest per
# eigenem helpdesk/sla_check-Endpunkt (kein Scheduler); Cache-Lock verhindert
# parallele Laeufe.
module RedmineExpertHelpdesk
  class SlaBreachCheck
    LOCK_KEY = 'redmine_expert_helpdesk/sla_breach_check_lock'.freeze

    # Liefert die Anzahl versendeter Benachrichtigungen, oder false wenn bereits
    # ein Lauf aktiv ist (Lock gehalten -> kein ueberlappender Check).
    def self.run_if_due
      return false unless Rails.cache.write(LOCK_KEY, Time.current.to_i, :unless_exist => true, :expires_in => 10.minutes)

      begin
        run
      ensure
        Rails.cache.delete(LOCK_KEY)
      end
    end

    # Liefert die Anzahl versendeter Benachrichtigungen.
    def self.run
      refresh_all_deadlines
      notified = 0

      HelpdeskProjectSetting.where(:sla_enabled => true, :sla_notify_enabled => true).find_each do |setting|
        project = Project.find_by(:id => setting.project_id)
        next unless project&.active?

        recipients = notify_recipients(setting)
        next if recipients.empty?

        scope = Issue.open.where(:project_id => project.id)
        scope = scope.where('created_on >= ?', setting.sla_enabled_at) if setting.sla_enabled_at.present?

        scope.find_each do |issue|
          state = Sla.state_for(issue)
          next unless state

          info = HelpdeskTicketInfo.find_or_initialize_by(:issue_id => issue.id)
          breached = []

          if state[:reaction] && state[:reaction][:status] == :breached && info.sla_reaction_notified_at.nil?
            breached << :reaction
            info.sla_reaction_notified_at = Time.current
          end
          if state[:solution] && state[:solution][:status] == :breached && info.sla_solution_notified_at.nil?
            breached << :solution
            info.sla_solution_notified_at = Time.current
          end
          next if breached.empty?

          info.save!
          HelpdeskSlaMailer.deliver_sla_breach(recipients, issue, breached, state)
          notified += 1
          Rails.logger.warn "Helpdesk/SLA: Ueberschreitung Ticket ##{issue.id} (#{breached.join(', ')}) – Benachrichtigung an #{recipients.join(', ')}"
        rescue StandardError => e
          Rails.logger.error "Helpdesk/SLA: Breach-Check fuer Ticket ##{issue.id} fehlgeschlagen: #{e.message}"
        end
      end

      notified
    end

    # Vorberechnete SLA-Faelligkeiten aller aktiven SLA-Projekte auffrischen
    # (unabhaengig von der Benachrichtigung), damit die Grid-Spalten/-Filter
    # aktuell bleiben und Bestandstickets nachtraeglich befuellt werden.
    def self.refresh_all_deadlines
      HelpdeskProjectSetting.where(:sla_enabled => true).find_each do |setting|
        project = Project.find_by(:id => setting.project_id)
        next unless project&.active?

        Sla.refresh_project_deadlines!(project)
      rescue StandardError => e
        Rails.logger.error "Helpdesk/SLA: Deadline-Refresh fuer Projekt #{setting.project_id} fehlgeschlagen: #{e.message}"
      end
    end

    def self.notify_recipients(setting)
      recipients = []
      recipients << setting.sla_notify_email.strip if setting.sla_notify_email.present?
      if setting.sla_notify_user_id.present?
        user = User.active.find_by(:id => setting.sla_notify_user_id)
        recipients << user.mail if user&.mail.present?
      end
      recipients.uniq
    end
  end
end
