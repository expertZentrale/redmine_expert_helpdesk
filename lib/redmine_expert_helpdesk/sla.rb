# SLA-Kernlogik: Zielzeiten aufloesen (Prio-Override -> Projekt-Default),
# Uhren-Status berechnen und Tracking-Ereignisse festhalten.
#
# Status je Uhr:
#   :met           - erledigt innerhalb der Zielzeit
#   :breached_done - erledigt, aber Zielzeit ueberschritten
#   :running       - laeuft, < 80 % der Zielzeit verbraucht
#   :warning       - laeuft, >= 80 % der Zielzeit verbraucht
#   :breached      - laeuft, Zielzeit ueberschritten
module RedmineExpertHelpdesk
  class Sla
    WARNING_RATIO = 0.8

    # SLA gilt fuer ein Ticket, wenn: im Projekt aktiviert UND das Ticket nach
    # der Aktivierung erstellt wurde (verhindert, dass beim Einschalten alle
    # Bestandstickets sofort "rot" werden).
    def self.enabled_for?(issue, setting = nil)
      setting ||= HelpdeskProjectSetting.for_project(issue.project)
      return false unless setting.persisted? && setting.sla_enabled?
      return false if setting.sla_enabled_at.present? && issue.created_on < setting.sla_enabled_at

      true
    end

    # Zielzeiten in Geschaeftsminuten: Prioritaets-Override vor Projekt-Default.
    def self.targets_for(issue, setting = nil)
      setting ||= HelpdeskProjectSetting.for_project(issue.project)
      override = HelpdeskSlaPriority.find_by(:project_id => issue.project_id, :priority_id => issue.priority_id)
      {
        :reaction => override&.reaction_minutes.presence || setting.sla_reaction_minutes,
        :solution => override&.solution_minutes.presence || setting.sla_solution_minutes
      }
    end

    # Gesamtstatus beider Uhren, nil wenn SLA nicht gilt.
    def self.state_for(issue, info = nil)
      setting = HelpdeskProjectSetting.for_project(issue.project)
      return nil unless enabled_for?(issue, setting)

      info  ||= HelpdeskTicketInfo.for_issue(issue)
      targets = targets_for(issue, setting)
      solution_done_at = issue.closed? ? issue.closed_on : nil

      # Reaktionsuhr endet spaetestens beim Loesen/Schliessen des Tickets: liegt
      # keine erfasste Erstreaktion vor, gilt der Schliesszeitpunkt als Abschluss
      # (sonst liefe die Reaktionsuhr auf geschlossenen Tickets ewig weiter und
      # koennte nie erfuellt/ueberschritten sein).
      first_response = info&.first_response_at
      reaction_done_at = first_response || solution_done_at
      reaction_minutes = first_response ? info&.reaction_business_minutes : nil

      {
        :reaction => clock_state(issue, targets[:reaction], reaction_done_at,
                                 reaction_minutes, setting),
        :solution => clock_state(issue, targets[:solution], solution_done_at,
                                 info&.solution_business_minutes, setting)
      }
    end

    # Status einer einzelnen Uhr, nil wenn kein Ziel konfiguriert.
    def self.clock_state(issue, target_minutes, done_at, done_minutes, setting)
      target = target_minutes.to_i
      return nil if target <= 0

      bh = BusinessHours.new(setting)

      if done_at.present?
        minutes = done_minutes || bh.elapsed_minutes(issue.created_on, done_at)
        {
          :status  => minutes <= target ? :met : :breached_done,
          :minutes => minutes,
          :target  => target
        }
      else
        elapsed = bh.elapsed_minutes(issue.created_on, Time.current)
        status  = if elapsed > target
                    :breached
                  elsif elapsed >= (target * WARNING_RATIO).floor
                    :warning
                  else
                    :running
                  end
        {
          :status  => status,
          :minutes => elapsed,
          :target  => target,
          :due_at  => bh.due_at(issue.created_on, target)
        }
      end
    end

    # --- Vorberechnete Faelligkeiten (fuer Ticket-Grid-Spalten/-Filter) ------

    # Berechnet und speichert die absoluten Faelligkeits-Zeitpunkte beider Uhren
    # auf dem HelpdeskTicketInfo-Satz. Bei nicht (mehr) gueltigem SLA werden die
    # Werte geleert. Wiederverwendet BusinessHours#due_at und targets_for.
    def self.refresh_deadlines!(issue, info = nil)
      setting = HelpdeskProjectSetting.for_project(issue.project)
      info  ||= HelpdeskTicketInfo.for_issue(issue)

      unless enabled_for?(issue, setting)
        return if info.nil?

        info.assign_attributes(:sla_reaction_due_at => nil, :sla_reaction_warn_at => nil,
                               :sla_solution_due_at => nil, :sla_solution_warn_at => nil)
        info.save! if info.persisted? && info.changed?
        return
      end

      info  ||= HelpdeskTicketInfo.find_or_initialize_by(:issue_id => issue.id)
      targets = targets_for(issue, setting)
      bh      = BusinessHours.new(setting)
      r       = targets[:reaction].to_i
      s       = targets[:solution].to_i

      info.sla_reaction_due_at  = r > 0 ? bh.due_at(issue.created_on, r) : nil
      info.sla_reaction_warn_at = r > 0 ? bh.due_at(issue.created_on, (r * WARNING_RATIO).floor) : nil
      info.sla_solution_due_at  = s > 0 ? bh.due_at(issue.created_on, s) : nil
      info.sla_solution_warn_at = s > 0 ? bh.due_at(issue.created_on, (s * WARNING_RATIO).floor) : nil

      info.save! if info.changed?
    rescue StandardError => e
      Rails.logger.warn "Helpdesk/SLA: refresh_deadlines fuer Ticket ##{issue.id} fehlgeschlagen: #{e.message}"
    end

    # Guenstiger Status einer Uhr aus den gespeicherten Zeitstempeln (spiegelt die
    # SQL-CASE-Logik der Grid-Spalten, ohne Geschaeftszeit-Schleife). nil = kein SLA.
    def self.clock_status_from(due_at, warn_at, done_at)
      return nil if due_at.nil?

      if done_at.present?
        done_at <= due_at ? :met : :breached_done
      else
        now = Time.current
        if now > due_at
          :breached
        elsif warn_at && now >= warn_at
          :warning
        else
          :running
        end
      end
    end

    # Faelligkeiten aller offenen, SLA-relevanten Tickets eines Projekts neu
    # berechnen (nach Aenderung der Projekt-/Prioritaets-Einstellungen).
    def self.refresh_project_deadlines!(project)
      Issue.open.where(:project_id => project.id).find_each do |issue|
        refresh_deadlines!(issue)
      end
    end

    # --- Tracking-Ereignisse -------------------------------------------------

    # Erste Reaktion festhalten (oeffentlicher Kommentar oder Kundenantwort-Mail).
    def self.record_first_response!(issue, at)
      setting = HelpdeskProjectSetting.for_project(issue.project)
      return unless setting.persisted? && setting.sla_enabled?

      info = HelpdeskTicketInfo.find_or_initialize_by(:issue_id => issue.id)
      return if info.first_response_at.present?

      info.first_response_at = at
      info.reaction_business_minutes = BusinessHours.new(setting).elapsed_minutes(issue.created_on, at)
      info.save!
    rescue StandardError => e
      Rails.logger.warn "Helpdesk/SLA: record_first_response fuer Ticket ##{issue.id} fehlgeschlagen: #{e.message}"
    end

    # Loesungszeit beim Schliessen berechnen bzw. beim Wiedereroeffnen zuruecksetzen.
    def self.sync_solution!(issue)
      setting = HelpdeskProjectSetting.for_project(issue.project)
      return unless setting.persisted? && setting.sla_enabled?

      info = HelpdeskTicketInfo.find_or_initialize_by(:issue_id => issue.id)

      if issue.closed? && issue.closed_on.present?
        return if info.solution_business_minutes.present?

        info.solution_business_minutes = BusinessHours.new(setting).elapsed_minutes(issue.created_on, issue.closed_on)
      else
        return if info.solution_business_minutes.nil? && info.sla_solution_notified_at.nil?

        info.solution_business_minutes = nil
        info.sla_solution_notified_at  = nil
      end
      info.save!
    rescue StandardError => e
      Rails.logger.warn "Helpdesk/SLA: sync_solution fuer Ticket ##{issue.id} fehlgeschlagen: #{e.message}"
    end
  end
end
