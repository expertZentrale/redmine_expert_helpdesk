# Import von Altdaten aus dem RedmineUP-Plugin redmine_contacts / redmine_contacts_helpdesk.
#
# Liest die alten Tabellen direkt per SQL (die Plugins selbst sind nicht mehr installiert):
#   - contacts          (Kontaktdaten: Name, Firma, E-Mail, Telefon, ...)
#   - contacts_projects (Zuordnung Kontakt -> Projekte)
#   - helpdesk_tickets  (autoritative Zuordnung Ticket -> Kunde, inkl. Message-ID)
#   - contacts_issues   (nur Fallback: generische "zugeordnete Kontakte", NICHT der Kunde!)
#
# Der Import ist idempotent:
#   - Kontakte, die (E-Mail + Projekt) bereits existieren, werden uebersprungen
#   - Tickets mit korrekter bestehender Verknuepfung werden uebersprungen
#   - Frueher falsch verknuepfte synthetische Import-Messages (aus contacts_issues)
#     werden repariert, wenn helpdesk_tickets einen anderen Kunden nennt
#
# Alte Tickets werden ueber eine synthetische HelpdeskMessage (direction 'in',
# ohne Mailbox) mit dem Kontakt verknuepft, damit die Kundenkarte auf der
# Ticketseite erscheint. message_id/sent_at werden aus helpdesk_tickets
# uebernommen (verbessert das Antwort-Threading fuer Alt-Tickets).
module RedmineExpertHelpdesk
  class LegacyContactsImport
    Result = Struct.new(:contacts_created, :contacts_existing, :contacts_without_email,
                        :issue_links_created, :issue_links_repaired, :issues_skipped) do
      def to_h
        { :contacts_created => contacts_created, :contacts_existing => contacts_existing,
          :contacts_without_email => contacts_without_email,
          :issue_links_created => issue_links_created,
          :issue_links_repaired => issue_links_repaired, :issues_skipped => issues_skipped }
      end
    end

    # Sind Altdaten vorhanden?
    def self.available?
      conn = ActiveRecord::Base.connection
      conn.table_exists?('contacts') && conn.select_value('SELECT COUNT(*) FROM contacts').to_i > 0
    end

    def self.legacy_contact_count
      ActiveRecord::Base.connection.select_value('SELECT COUNT(*) FROM contacts').to_i
    rescue StandardError
      0
    end

    # Projekte (inkl. "kein Projekt"-Bucket) mit Anzahl Alt-Kontakte, fuer die
    # Auswahl auf der Import-Seite. Liefert je Projekt (und "kein Projekt"-Bucket,
    # project_id nil) die Anzahl Alt-Kontakte, getrennt nach:
    #   :with_issues    – Kontakt hat Tickets in diesem Projekt (ticket-basiert)
    #   :without_issues – nur zugeordnet (contacts_projects), ohne Tickets im Projekt
    # [{ :project_id, :name, :with_issues, :without_issues, :count }, ...]; name nil =
    # Projekt existiert nicht mehr. Sortiert nach Name, "kein Projekt" zuletzt.
    def self.legacy_project_options
      inst = new
      conn = inst.send(:conn)

      # Projekte je Kontakt aus Tickets (mit Tickets) und aus contacts_projects.
      ticket_map   = Hash.new { |h, k| h[k] = [] }
      assigned_map = Hash.new { |h, k| h[k] = [] }
      source = inst.send(:issue_link_source)
      conn.select_all(
        "SELECT DISTINCT l.contact_id, i.project_id " \
        "FROM #{source} l INNER JOIN issues i ON i.id = l.issue_id"
      ).each { |r| ticket_map[r['contact_id']] << r['project_id'].to_i }
      conn.select_all('SELECT contact_id, project_id FROM contacts_projects').each do |r|
        assigned_map[r['contact_id']] << (r['project_id'] && r['project_id'].to_i)
      end

      with    = Hash.new(0)
      without = Hash.new(0)
      conn.select_all('SELECT id, email FROM contacts').each do |row|
        next if row['email'].to_s.split(/[,;]/).first.to_s.strip.blank?

        tprojects = ticket_map[row['id']].uniq
        all       = (tprojects + assigned_map[row['id']]).uniq
        all       = [nil] if all.empty?
        all.each do |pid|
          (tprojects.include?(pid) ? with : without)[pid] += 1
        end
      end

      keys  = (with.keys + without.keys).uniq
      names = Project.where(:id => keys.compact).pluck(:id, :name).to_h
      keys.map do |pid|
        { :project_id     => pid,
          :name           => (pid.nil? ? nil : names[pid]),
          :with_issues    => with[pid],
          :without_issues => without[pid],
          :count          => with[pid] + without[pid] }
      end.sort_by { |o| [o[:project_id].nil? ? 1 : 0, o[:name].to_s.downcase] }
    end

    # Anhaenge (Original-Mails als EML), die noch am alten HelpdeskTicket-Container
    # haengen und daher in Redmine nicht sichtbar sind.
    def self.misplaced_attachment_count
      ActiveRecord::Base.connection.select_value(
        "SELECT COUNT(*) FROM attachments WHERE container_type = 'HelpdeskTicket'"
      ).to_i
    rescue StandardError
      0
    end

    # project_ids: nil = alle Projekte importieren (Standard/rueckwaertskompatibel).
    # Sonst ein Array ausgewaehlter Projekt-IDs; 'none'/leer waehlt zusaetzlich den
    # "kein Projekt"-Bucket (Kontakte ohne Projektzuordnung).
    def initialize(project_ids = nil)
      if project_ids.nil?
        @filter = nil
      else
        values = Array(project_ids).map(&:to_s)
        @include_no_project = values.any? { |v| v == 'none' || v.strip.empty? }
        @filter = values.reject { |v| v == 'none' || v.strip.empty? }.map(&:to_i)
      end
    end

    # Soll dieses Projekt importiert werden? (project_id nil = "kein Projekt")
    def selected?(project_id)
      return true if @filter.nil?
      return @include_no_project if project_id.nil?

      @filter.include?(project_id.to_i)
    end

    def run
      result = Result.new(0, 0, 0, 0, 0, 0)
      import_contacts(result)
      link_issues(result)
      Rails.logger.info "Helpdesk: Legacy-Kontaktimport abgeschlossen – #{result.to_h.inspect}"
      result
    end

    FixResult = Struct.new(:attachments_fixed, :attachments_orphaned, :messages_linked)

    # Haengt Alt-Anhaenge (container_type 'HelpdeskTicket', meist message.eml)
    # an das zugehoerige Ticket um, damit sie in Redmine wieder sichtbar sind.
    # Die Zuordnung HelpdeskTicket-ID -> Issue-ID kommt aus helpdesk_tickets.
    # Zusaetzlich werden synthetische Import-Messages ohne EML-Verweis mit der
    # Original-Mail verknuepft ("Original-Mail"-Link auf der Ticketseite).
    def fix_attachments
      result = FixResult.new(0, 0, 0)
      return result unless conn.table_exists?('helpdesk_tickets')

      total = self.class.misplaced_attachment_count
      result.attachments_fixed = conn.update(<<~SQL)
        UPDATE attachments a
        INNER JOIN helpdesk_tickets ht ON ht.id = a.container_id
        SET a.container_type = 'Issue', a.container_id = ht.issue_id
        WHERE a.container_type = 'HelpdeskTicket'
      SQL
      result.attachments_orphaned = total - result.attachments_fixed

      # EML mit synthetischen Import-Messages verknuepfen (nur ohne Mailbox,
      # echte Mail-Verlaeufe haben ihren EML-Verweis bereits)
      result.messages_linked = conn.update(<<~SQL)
        UPDATE helpdesk_messages hm
        INNER JOIN attachments a
          ON a.container_type = 'Issue'
         AND a.container_id   = hm.issue_id
         AND a.content_type   = 'message/rfc822'
        SET hm.eml_attachment_id = a.id
        WHERE hm.eml_attachment_id IS NULL
          AND hm.helpdesk_mailbox_id IS NULL
      SQL

      Rails.logger.info "Helpdesk: EML-Anhang-Reparatur abgeschlossen – " \
                        "#{result.attachments_fixed} umgehaengt, #{result.attachments_orphaned} verwaist, " \
                        "#{result.messages_linked} Messages verknuepft"
      result
    end

    private

    def conn
      ActiveRecord::Base.connection
    end

    def import_contacts(result)
      contacts = conn.select_all(
        'SELECT id, first_name, last_name, middle_name, company, is_company, phone, email, background FROM contacts'
      ).to_a

      project_map = contact_project_map

      contacts.each do |row|
        email = primary_email(row['email'])
        if email.blank?
          result.contacts_without_email += 1
          next
        end

        name    = build_name(row)
        company = row['company'].to_s.strip.presence
        phone   = primary_phone(row['phone'])
        notes   = row['background'].to_s.strip.presence

        project_ids = (project_map[row['id']] || [nil]).select { |pid| selected?(pid) }
        next if project_ids.empty?

        project_ids.each do |project_id|
          if project_id && !Project.exists?(project_id)
            next
          end

          existing = HelpdeskContact.where(:project_id => project_id)
                                    .where('LOWER(email) = ?', email).first
          if existing
            result.contacts_existing += 1
            next
          end

          HelpdeskContact.create!(
            :email      => email,
            :name       => name,
            :company    => company,
            :phone      => phone,
            :notes      => notes,
            :project_id => project_id
          )
          result.contacts_created += 1
        end
      end
    end

    # Projekt-Zuordnungen je Kontakt: contacts_projects + Projekte der Tickets,
    # bei denen der Kontakt laut helpdesk_tickets der Kunde ist
    def contact_project_map
      map = Hash.new { |h, k| h[k] = [] }

      conn.select_all('SELECT contact_id, project_id FROM contacts_projects').each do |row|
        map[row['contact_id']] << row['project_id']
      end

      source = issue_link_source
      conn.select_all(
        "SELECT DISTINCT l.contact_id, i.project_id " \
        "FROM #{source} l INNER JOIN issues i ON i.id = l.issue_id"
      ).each do |row|
        map[row['contact_id']] << row['project_id']
      end

      map.transform_values(&:uniq)
    end

    # Autoritative Quelle fuer Ticket->Kunde: helpdesk_tickets (redmine_contacts_helpdesk).
    # contacts_issues ist nur die generische "zugeordnete Kontakte"-Tabelle (Fallback).
    def issue_link_source
      @issue_link_source ||= conn.table_exists?('helpdesk_tickets') ? 'helpdesk_tickets' : 'contacts_issues'
    end

    # Alte Ticket-Verknuepfungen: synthetische HelpdeskMessage pro Ticket anlegen,
    # damit die Kundenkarte auf der Ticketseite erscheint. Bereits vorhandene
    # synthetische Messages (fruehere Import-Laeufe) mit falschem Kontakt werden repariert.
    def link_issues(result)
      if issue_link_source == 'helpdesk_tickets'
        rows = conn.select_all(
          'SELECT ht.issue_id, ht.message_id, ht.ticket_date, ' \
          'c.email, c.first_name, c.last_name, c.middle_name, c.company, c.is_company ' \
          'FROM helpdesk_tickets ht INNER JOIN contacts c ON c.id = ht.contact_id'
        ).to_a
      else
        rows = conn.select_all(
          'SELECT ci.issue_id, NULL AS message_id, NULL AS ticket_date, ' \
          'c.email, c.first_name, c.last_name, c.middle_name, c.company, c.is_company ' \
          'FROM contacts_issues ci INNER JOIN contacts c ON c.id = ci.contact_id'
        ).to_a
      end

      rows.each do |row|
        email = primary_email(row['email'])
        next if email.blank?

        issue = Issue.find_by(:id => row['issue_id'])
        next unless issue&.project
        next unless selected?(issue.project_id)

        contact  = HelpdeskContact.find_or_create_for(email, build_name(row), issue.project)
        existing = HelpdeskMessage.where(:issue_id => issue.id).order(:id => :asc).first

        if existing
          # Echte Mail-Verlaeufe (mit Mailbox) nie anfassen; nur synthetische
          # Import-Messages mit abweichendem Kontakt reparieren.
          if existing.helpdesk_mailbox_id.nil? && existing.helpdesk_contact_id != contact.id
            existing.update_columns(
              :helpdesk_contact_id => contact.id,
              :message_id          => normalized_message_id(row['message_id']) || existing.message_id
            )
            HelpdeskTicketInfo.for_issue(issue)&.update_columns(:helpdesk_contact_id => contact.id) ||
              HelpdeskTicketInfo.link!(issue, contact)
            result.issue_links_repaired += 1
          else
            HelpdeskTicketInfo.link!(issue, existing.helpdesk_contact, existing.helpdesk_mailbox)
            result.issues_skipped += 1
          end
          next
        end

        HelpdeskMessage.create!(
          :issue            => issue,
          :helpdesk_contact => contact,
          :direction        => 'in',
          :message_id       => normalized_message_id(row['message_id']),
          :subject          => issue.subject,
          :sent_at          => row['ticket_date'].presence || issue.created_on
        )
        HelpdeskTicketInfo.link!(issue, contact)
        result.issue_links_created += 1
      rescue StandardError => e
        Rails.logger.warn "Helpdesk: Legacy-Import fuer Ticket ##{row['issue_id']} fehlgeschlagen: #{e.message}"
      end
    end

    def normalized_message_id(value)
      value.to_s.delete('<>').strip.presence
    end

    # redmine_contacts erlaubt mehrere kommagetrennte Adressen – erste verwenden
    def primary_email(value)
      value.to_s.split(/[,;]/).first.to_s.downcase.strip
    end

    def primary_phone(value)
      value.to_s.split(/[,;]/).first.to_s.strip.presence
    end

    # Firmen-Kontakte (is_company) tragen den Namen im company-Feld
    def build_name(row)
      truthy = [true, 1, '1', 't'].include?(row['is_company'])
      if truthy
        row['company'].to_s.strip.presence
      else
        [row['first_name'], row['middle_name'], row['last_name']]
          .map { |p| p.to_s.strip }.reject(&:empty?).join(' ').presence
      end
    end
  end
end
