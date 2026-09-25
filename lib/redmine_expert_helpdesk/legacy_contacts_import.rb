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

    # Legacy original mails (message.eml) that still hang off a redmine_contacts_helpdesk
    # HelpdeskTicket and can be moved onto that ticket's issue. Rows whose HelpdeskTicket
    # is gone (container_id NULL or unknown) are not counted: nothing can repair them,
    # and counting them kept the repair button on screen forever.
    def self.misplaced_attachment_count
      inst = new
      inst.send(:conn).select_value("SELECT COUNT(*) FROM (#{inst.send(:fixable_sql)}) x").to_i
    rescue StandardError
      0
    end

    # Is RedmineUP's helpdesk still installed? Only then does handing mails back to its
    # HelpdeskTicket make sense - without it that container is unreadable.
    def self.redmineup_helpdesk_installed?
      Redmine::Plugin.installed?(:redmine_contacts_helpdesk)
    end

    # Per-project counts for the EML selection page:
    # [{ :project_id, :name, :fixable, :restorable }, ...] sorted by name. The restore
    # count needs a grouped scan over every legacy ticket (seconds on a large dataset),
    # which is why it lives on the selection page and not on the settings page.
    def self.attachment_project_options
      inst       = new
      fixable    = inst.send(:count_by_project, inst.send(:fixable_sql))
      restorable = redmineup_helpdesk_installed? ? inst.send(:count_by_project, inst.send(:restorable_sql)) : {}
      ids   = (fixable.keys + restorable.keys).uniq
      names = Project.where(:id => ids).pluck(:id, :name).to_h
      ids.map do |pid|
        { :project_id => pid, :name => names[pid],
          :fixable => fixable[pid].to_i, :restorable => restorable[pid].to_i }
      end.sort_by { |o| o[:name].to_s.strip.downcase } # names may carry a leading blank
    end

    # project_ids: nil = alle Projekte importieren (Standard/rueckwaertskompatibel).
    # Sonst ein Array ausgewaehlter Projekt-IDs; 'none'/leer waehlt zusaetzlich den
    # "kein Projekt"-Bucket (Kontakte ohne Projektzuordnung).
    # progress: optional callable(phase, done, total), called per processed row -
    # HelpdeskLegacyImportJob feeds it into the run row the status page polls.
    def initialize(project_ids = nil, progress: nil)
      @progress = progress
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

    FixResult     = Struct.new(:attachments_fixed, :attachments_orphaned, :messages_linked)
    RestoreResult = Struct.new(:attachments_restored)

    # Moves are done in batches by id: portable SQL, and the progress callback - which
    # also fences a superseded run - gets a say between batches.
    MOVE_BATCH = 500

    # Haengt Alt-Anhaenge (container_type 'HelpdeskTicket', meist message.eml)
    # an das zugehoerige Ticket um, damit sie in Redmine wieder sichtbar sind.
    # Die Zuordnung HelpdeskTicket-ID -> Issue-ID kommt aus helpdesk_tickets.
    # Zusaetzlich werden synthetische Import-Messages ohne EML-Verweis mit der
    # Original-Mail verknuepft ("Original-Mail"-Link auf der Ticketseite).
    # Only the selected projects (see #initialize) are touched.
    def fix_attachments
      result = FixResult.new(0, 0, 0)
      return result unless conn.table_exists?('helpdesk_tickets')

      pairs = fixable_attachments.map { |id, issue_id, _| [id, issue_id] }
      result.attachments_fixed = move_attachments(pairs, 'HelpdeskTicket', 'Issue', 'attachments')
      # Unrepairable leftovers (their HelpdeskTicket is gone) - reported, not touched
      result.attachments_orphaned = conn.select_value(<<~SQL).to_i
        SELECT COUNT(*) FROM attachments a
        LEFT JOIN helpdesk_tickets ht ON ht.id = a.container_id
        WHERE a.container_type = 'HelpdeskTicket' AND ht.id IS NULL
      SQL

      report('messages', 0, 1)
      # EML mit synthetischen Import-Messages verknuepfen (nur ohne Mailbox,
      # echte Mail-Verlaeufe haben ihren EML-Verweis bereits)
      result.messages_linked = conn.update(<<~SQL)
        UPDATE helpdesk_messages hm
        INNER JOIN issues i ON i.id = hm.issue_id
        INNER JOIN attachments a
          ON a.container_type = 'Issue'
         AND a.container_id   = hm.issue_id
         AND a.content_type   = 'message/rfc822'
        SET hm.eml_attachment_id = a.id
        WHERE hm.eml_attachment_id IS NULL
          AND hm.helpdesk_mailbox_id IS NULL
          #{project_condition('i.project_id')}
      SQL

      Rails.logger.info "Helpdesk: EML-Anhang-Reparatur abgeschlossen – " \
                        "#{result.attachments_fixed} umgehaengt, #{result.attachments_orphaned} verwaist, " \
                        "#{result.messages_linked} Messages verknuepft"
      result
    end

    # The reverse of #fix_attachments, for projects that still run RedmineUP's helpdesk:
    # hands message.eml back to its HelpdeskTicket so RedmineUP finds its original mail
    # again. Our own "Original-Mail" link addresses the file by attachment id and keeps
    # working. Only unambiguous cases (see #restorable_attachments) are moved.
    def restore_attachments
      result = RestoreResult.new(0)
      return result unless conn.table_exists?('helpdesk_tickets')

      pairs = restorable_attachments.map { |id, ticket_id, _| [id, ticket_id] }
      result.attachments_restored = move_attachments(pairs, 'Issue', 'HelpdeskTicket', 'restore')
      Rails.logger.info "Helpdesk: EML-Anhaenge an RedmineUP zurueckgegeben – #{result.attachments_restored}"
      result
    end

    private

    # [[attachment_id, issue_id, project_id], ...] - legacy mails whose HelpdeskTicket
    # still exists, in the selected projects.
    def fixable_attachments
      return [] unless conn.table_exists?('helpdesk_tickets')

      conn.select_rows(fixable_sql).map { |r| r.map(&:to_i) }
    end

    # Driven from helpdesk_tickets so the attachments index on
    # (container_id, container_type) is used instead of scanning every attachment.
    def fixable_sql
      <<~SQL
        SELECT a.id AS attachment_id, ht.issue_id AS target_id, i.project_id AS project_id
        FROM helpdesk_tickets ht
        INNER JOIN issues i ON i.id = ht.issue_id
        INNER JOIN attachments a ON a.container_id = ht.id AND a.container_type = 'HelpdeskTicket'
        WHERE 1 = 1 #{project_condition('i.project_id')}
      SQL
    end

    # [[attachment_id, helpdesk_ticket_id, project_id], ...] - message.eml on an issue
    # that can go back to its HelpdeskTicket without guessing.
    def restorable_attachments
      return [] unless conn.table_exists?('helpdesk_tickets')

      conn.select_rows(restorable_sql).map { |r| r.map(&:to_i) }
    end

    # One row per issue that has exactly one HelpdeskTicket and exactly one message.eml
    # (any content type counts towards "exactly one"; the survivor must be RFC 822),
    # and none of whose tickets holds a mail yet - checked in HAVING, across all of the
    # issue's tickets, so an issue with two tickets is never half-matched. Issues that
    # were deleted drop out via the issues join. Our own archived mails are named
    # original_mail_*.eml and never match.
    def restorable_sql
      <<~SQL
        SELECT MIN(a.id) AS attachment_id, MIN(ht.id) AS target_id, MIN(i.project_id) AS project_id
        FROM helpdesk_tickets ht
        INNER JOIN issues i ON i.id = ht.issue_id
        INNER JOIN attachments a
          ON a.container_id = ht.issue_id AND a.container_type = 'Issue' AND a.filename = 'message.eml'
        LEFT JOIN attachments cur ON cur.container_id = ht.id AND cur.container_type = 'HelpdeskTicket'
        WHERE 1 = 1 #{project_condition('i.project_id')}
        GROUP BY ht.issue_id
        HAVING COUNT(DISTINCT ht.id) = 1 AND COUNT(DISTINCT a.id) = 1 AND COUNT(cur.id) = 0
           AND MIN(a.content_type) LIKE 'message/rfc822%'
      SQL
    end

    # { project_id => count } over one of the *_sql selections
    def count_by_project(sql)
      return {} unless conn.table_exists?('helpdesk_tickets')

      conn.select_rows("SELECT x.project_id, COUNT(*) FROM (#{sql}) x GROUP BY x.project_id")
          .to_h { |pid, n| [pid.to_i, n.to_i] }
    end

    # AND-clause restricting to the selected projects; empty when all are selected.
    # Attachments always belong to a project, so the "no project" bucket selects nothing.
    def project_condition(column)
      return '' if @filter.nil?
      return 'AND 1 = 0' if @filter.empty?

      "AND #{column} IN (#{@filter.map(&:to_i).join(',')})"
    end

    # Re-points [[attachment_id, new_container_id], ...] from one container type to
    # another. The WHERE on the old type makes a batch a no-op for rows someone else
    # moved in the meantime. Returns the number of rows moved.
    def move_attachments(pairs, from_type, to_type, phase)
      moved = 0
      pairs.each_slice(MOVE_BATCH).with_index do |slice, index|
        report(phase, index * MOVE_BATCH, pairs.size)
        cases = slice.map { |id, container_id| "WHEN #{id.to_i} THEN #{container_id.to_i}" }.join(' ')
        moved += conn.update(<<~SQL)
          UPDATE attachments
          SET container_type = #{conn.quote(to_type)}, container_id = CASE id #{cases} END
          WHERE id IN (#{slice.map { |id, _| id.to_i }.join(',')})
            AND container_type = #{conn.quote(from_type)}
        SQL
      end
      report(phase, pairs.size, pairs.size)
      moved
    end

    def report(phase, done, total)
      @progress&.call(phase, done, total)
    end

    def conn
      ActiveRecord::Base.connection
    end

    def import_contacts(result)
      contacts = conn.select_all(
        'SELECT id, first_name, last_name, middle_name, company, is_company, phone, email, background FROM contacts'
      ).to_a

      project_map = contact_project_map

      contacts.each_with_index do |row, index|
        report('contacts', index + 1, contacts.size)
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

      # Progress is reported outside link_issue's per-row rescue: the job aborts a
      # superseded run by raising from the callback, which must not be swallowed.
      rows.each_with_index do |row, index|
        report('issues', index + 1, rows.size)
        link_issue(row, result)
      end
    end

    def link_issue(row, result)
      email = primary_email(row['email'])
      return if email.blank?

      issue = Issue.find_by(:id => row['issue_id'])
      return unless issue&.project
      return unless selected?(issue.project_id)

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
        return
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
