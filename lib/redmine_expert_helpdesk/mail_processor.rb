# Kernstueck des Helpdesk-Plugins: Verarbeitung eingehender Mails.
#
# Der Mail-Backend wird pro Postfach ueber MailProvider aufgeloest (Microsoft
# Graph oder generisches IMAP/SMTP); dieser Ablauf ist providerneutral.
#
# Ablauf pro Postfach:
#   1. Nachrichten ueber den Provider aus dem Quellordner laden
#   2. Check the sender against the black-/whitelist
#   3. Apply the "ignore" rules
#   4. Hand the MIME to Redmine's own MailHandler
#      (does ticket creation, reply matching via In-Reply-To / [#id] subject,
#       attachments and user creation)
#   5. Apply the rules to the created ticket, link the contact
#   6. Send the autoresponder for new tickets
#   7. Enqueue the AI summary and the completeness check asynchronously
#   8. Move the message to the target folder

module RedmineExpertHelpdesk
  class MailProcessor
    Result = Struct.new(:processed, :created_issues, :updated_issues, :skipped, :errors) do
      def to_h
        { :processed => processed, :created_issues => created_issues,
          :updated_issues => updated_issues, :skipped => skipped, :errors => errors }
      end
    end

    # The second argument stays positional for backwards compatibility - tests
    # inject a fake provider through it.
    def initialize(mailbox, provider = nil)
      @mailbox = mailbox
      @provider = provider || MailProvider.for(mailbox)
    end

    # Verarbeitet alle Nachrichten des Postfachs. Liefert ein Result-Objekt.
    def process_all(limit = 25)
      # One session for the whole cycle: IMAP opens a single connection here
      # instead of one per message. Graph ignores it.
      @provider.with_session { run_cycle(limit) }
    end

    private

    def run_cycle(limit)
      result = Result.new(0, [], [], 0, [])

      begin
        messages = Array(@provider.list_messages(limit))
      rescue StandardError => e
        msg = I18n.t(:error_helpdesk_fetch_failed, :message => e.message)
        Rails.logger.error "Helpdesk (#{@mailbox.mailbox_address}): #{msg}"
        @mailbox.update_columns(:last_error => msg, :last_error_at => Time.current)
        result.errors << { :subject => nil, :error => msg }
        return result
      end

      messages.each do |meta|
        begin
          process_message(meta, result)
        rescue StandardError => e
          Rails.logger.error "Helpdesk: Fehler bei Nachricht #{meta.id} (#{@mailbox.mailbox_address}): #{e.message}"
          result.errors << { :subject => meta.subject, :error => e.message }
          begin
            move_failed(meta.id)
          rescue StandardError => move_err
            Rails.logger.warn "Helpdesk: Nachricht #{meta.id} konnte nicht in Fehlerordner verschoben werden: #{move_err.message}"
          end
        end
      end

      if result.errors.any?
        last = result.errors.last
        error_text = last[:subject].present? ? "\"#{last[:subject]}\": #{last[:error]}" : last[:error]
        @mailbox.update_columns(
          :last_fetched_at => Time.current,
          :last_error      => error_text,
          :last_error_at   => Time.current
        )
      else
        @mailbox.update_columns(:last_fetched_at => Time.current, :last_error => nil, :last_error_at => nil)
      end

      result
    end

    def process_message(meta, result)
      sender = meta.from_address.to_s.downcase
      sender_name = meta.from_name.to_s
      subject = meta.subject.to_s

      # Black-/Whitelist und Ignorieren-Regeln: Nachricht bleibt unangetastet liegen?
      # Nein – abgelehnte Mails werden ebenfalls verschoben, damit sie nicht
      # bei jedem Abruf erneut geprueft werden.
      if sender_rejected?(sender) || ignore_rule_matches?(subject, sender)
        move_skipped(meta.id)
        result.skipped += 1
        return
      end

      mime = @provider.message_mime(meta.id)

      if auto_reply_filtered?(mime, sender)
        Rails.logger.info "Helpdesk (#{@mailbox.mailbox_address}): Auto-Reply ignoriert – #{subject.inspect} von #{sender}"
        move_skipped(meta.id)
        result.skipped += 1
        return
      end

      # Phishing-Pruefung gegen den lokalen Feed-Spiegel (pro Projekt aktivierbar).
      # 'quarantine': Mail mit bestaetigtem Treffer wird ohne Ticket in den Skipped-Ordner verschoben.
      # 'neutralize': Links werden im Body ersetzt, Verarbeitung laeuft weiter.
      # Verdachtsfaelle (Weiterleitung/Kurz-URL/Linktext-Mismatch) werden nur markiert,
      # nie quarantaenisiert (zu viele legitime Faelle, z. B. Newsletter-Tracking).
      phishing_hits = []
      phishing_suspicions = []
      if phishing_check_enabled?
        scan = PhishingScanner.scan(mime)
        if scan[:hits].any? && phishing_action == 'quarantine'
          Rails.logger.warn "Helpdesk (#{@mailbox.mailbox_address}): Phishing-Mail in Quarantaene – " \
                            "#{subject.inspect} von #{sender} (#{scan[:hits].size} URL(s))"
          move_skipped(meta.id)
          result.skipped += 1
          return
        end

        if scan[:hits].any? || scan[:suspicions].any?
          phishing_hits = scan[:hits]
          phishing_suspicions = scan[:suspicions]
          mime = scan[:mime]
          Rails.logger.warn "Helpdesk (#{@mailbox.mailbox_address}): #{phishing_hits.size} Phishing-URL(s) neutralisiert, " \
                            "#{phishing_suspicions.size} verschleierte(r) Link(s) markiert – #{subject.inspect} von #{sender}"
        end
      end

      # Vorverarbeitung: Wenn das referenzierte Ticket geschlossen und zu alt ist,
      # Thread-Header entfernen, damit MailHandler ein neues Ticket anlegt.
      mime = maybe_strip_thread_for_new_issue(mime)

      # NDR-Mails haben Auto-Submitted: auto-replied, was Redmines MailHandler
      # ebenfalls als Auto-Reply ablehnt. Header fuer NDRs entfernen.
      mime = strip_auto_submitted_for_ndr(mime)

      # Stellt sicher, dass Antworten auf Helpdesk-Mails dem richtigen Ticket
      # zugeordnet werden, auch wenn der Betreff kein [#id]-Tag enthaelt.
      mime = ensure_thread_reference(mime)

      # Inline images: make sure the body MailHandler keeps still references the
      # embedded images (only needed when Redmine builds the body from the HTML
      # part - see InlineImages). The original MIME stays untouched, it is what
      # gets archived as .eml further down.
      object = MailHandler.receive(InlineImages.prepare_mime(mime), mail_handler_options)

      unless object
        # MailHandler hat die Mail abgelehnt (z. B. eigene Adresse, ungueltig)
        move_skipped(meta.id)
        result.skipped += 1
        return
      end

      issue, new_issue = extract_issue(object)

      if issue
        # MailHandler has saved the embedded images as attachments but left their
        # "[cid:...]" references in the text - point them at those attachments so
        # the ticket shows the pictures instead of the markers.
        InlineImages.rewrite!(object, mime)

        apply_new_issue_defaults(issue, subject, sender) if new_issue
        reopened = new_issue ? false : reopen_if_closed(issue, (object.is_a?(Journal) ? object : nil))
        contact = HelpdeskContact.find_or_create_for(sender, sender_name, @mailbox.project)
        HelpdeskTicketInfo.link!(issue, contact, @mailbox)

        # Mark the ticket as waiting for an agent. Runs after link!, so the
        # HelpdeskTicketInfo row is guaranteed to exist. New tickets are not flagged
        # (they are new work by definition), and neither are mails an agent sent in
        # themselves.
        if !new_issue && HelpdeskTicketInfo.awaiting_agent_enabled? && !agent_authored?(object, issue)
          HelpdeskTicketInfo.mark_awaiting_agent!(
            issue, reopened ? 'reopen' : 'reply', meta.received_at || Time.current
          )
        end

        eml_author = (object.is_a?(Journal) ? object.user : issue.author) || User.anonymous

        parsed_mail = Mail.read_from_string(mime) rescue nil
        msg = HelpdeskMessage.create!(
          :issue             => issue,
          :helpdesk_contact  => contact,
          :helpdesk_mailbox  => @mailbox,
          :direction         => 'in',
          :message_id        => meta.internet_message_id,
          :subject           => subject,
          :sent_at           => meta.received_at,
          :recipient_to      => parsed_mail&.to&.join(', '),
          :recipient_cc      => parsed_mail&.cc&.join(', '),
          :journal_id        => (object.is_a?(Journal) ? object.id : nil)
        )

        eml_att = attach_eml(issue, mime, eml_author)
        if eml_att
          msg.update_column(:eml_attachment_id, eml_att.id)
          # Kein HTML mehr in die Journal-Notiz schreiben: Redmines Wiki-Sanitizer
          # entfernt class-Attribute, Styling ist so nicht moeglich. Die einzeilige
          # Mail-Kopfzeile wird clientseitig injiziert (_issue_sidebar.html.erb,
          # Badge im h4.note-header per Timestamp-Matching).
        end

        send_autoresponder(issue, contact, meta.internet_message_id) if new_issue && @mailbox.autoresponder_enabled?
        if phishing_hits.any? || phishing_suspicions.any?
          add_phishing_note(issue, phishing_hits, phishing_suspicions)
        end
        enqueue_ai_summary(issue, object, new_issue, msg)
        enqueue_completeness_check(issue, msg) if new_issue
        (new_issue ? result.created_issues : result.updated_issues) << issue.id
      end

      move_processed(meta.id)
      result.processed += 1
    end

    # Optionen fuer den Redmine MailHandler – Projekt und Standardwerte des Postfachs
    def mail_handler_options
      issue_attrs = { :project => @mailbox.project.identifier }
      issue_attrs[:tracker]  = @mailbox.default_tracker.name  if @mailbox.default_tracker
      issue_attrs[:priority] = @mailbox.default_priority.name if @mailbox.default_priority
      issue_attrs[:status]   = @mailbox.default_status.name   if @mailbox.default_status

      {
        :issue               => issue_attrs,
        :unknown_user        => @mailbox.unknown_user_mode.presence || 'accept',
        :no_account_notice   => '1',
        :no_permission_check => '1',
        :no_notification     => @mailbox.suppress_notifications? ? '1' : nil
      }.compact
    end

    def extract_issue(object)
      case object
      when Issue   then [object, true]
      when Journal then [object.journalized.is_a?(Issue) ? object.journalized : nil, false]
      else [nil, false]
      end
    end

    # KI-Zusammenfassung asynchron anstossen (nicht blockierend). Prueft globale
    # und projektspezifische Aktivierung sowie den Umfang (nur Erstmail vs. auch
    # Antworten), damit ohne aktivierte Funktion kein Job in die Queue geht.
    # Fehler beim Enqueue duerfen die Mailverarbeitung nicht abbrechen.
    def enqueue_ai_summary(issue, object, new_issue, msg)
      return unless RedmineExpertHelpdesk::AiFeatures.ai_enabled?

      ps = HelpdeskProjectSetting.for_project(issue.project)
      return unless ps.ai_summary_enabled?
      return if !new_issue && !ps.ai_summary_for_replies?

      HelpdeskAiSummaryJob.perform_later(
        issue.id,
        :journal_id => (object.is_a?(Journal) ? object.id : nil),
        :message_id => msg.id
      )
    rescue => e
      Rails.logger.warn("[helpdesk][ai] Enqueue fehlgeschlagen (Issue ##{issue.id}): #{e.message}")
    end

    # Enqueue the completeness check of the first mail. New tickets only: a reply in
    # a running conversation must never trigger an automatic follow-up. The cheap
    # switches are checked here already, so no job is queued while the feature is
    # off. An enqueue failure must not abort mail processing.
    def enqueue_completeness_check(issue, msg)
      return unless Setting.plugin_redmine_expert_helpdesk['info_request_enabled'].to_s == '1'
      return unless HelpdeskProjectSetting.for_project(issue.project).info_request_enabled?

      HelpdeskCompletenessJob.perform_later(issue.id, :message_id => msg.id)
    rescue => e
      Rails.logger.warn("[helpdesk][info_request] Enqueue fehlgeschlagen " \
                        "(Issue ##{issue.id}): #{e.message}")
    end

    # --- Ticket-Wiedereroeffnung --------------------------------------------

    # Entfernt Thread-Header aus der MIME-Nachricht, wenn das referenzierte
    # Ticket geschlossen UND aelter als reopen_max_age_days ist.
    # Dadurch legt MailHandler ein neues Ticket an statt einen Kommentar anzuhaengen.
    def maybe_strip_thread_for_new_issue(mime)
      return mime unless @mailbox.reopen_max_age_days.to_i > 0

      msg = Mail.read_from_string(mime)
      issue = find_referenced_issue(msg)
      return mime unless issue&.status&.is_closed?

      age_days = (Time.current.to_f - issue.updated_on.to_f) / 86_400.0
      return mime if age_days <= @mailbox.reopen_max_age_days.to_i

      Rails.logger.info "Helpdesk (#{@mailbox.mailbox_address}): Ticket ##{issue.id} ist #{age_days.round} Tage geschlossen " \
                        "(Limit: #{@mailbox.reopen_max_age_days} Tage) – neues Ticket wird erstellt"

      msg['in-reply-to'] = nil
      msg['references']  = nil
      msg.subject = msg.subject.to_s.gsub(/\s*\[#\d+\]\s*/, ' ').strip
      msg.to_s
    rescue StandardError => e
      Rails.logger.warn "Helpdesk: Thread-Vorverarbeitung fehlgeschlagen: #{e.message}"
      mime
    end

    # Sucht das im Betreff referenzierte Ticket (Muster [#ID]).
    # Fallback: HelpdeskMessage-Tabelle per Internet-Message-ID aus In-Reply-To.
    def find_referenced_issue(msg)
      if msg.subject.to_s =~ /\[#(\d+)\]/
        issue = Issue.find_by(:id => $1.to_i)
        return issue if issue
      end

      ref_ids = [msg['in-reply-to']&.value.to_s, msg['references']&.value.to_s]
                .join(' ').scan(/<([^>]+)>/).flatten
      if ref_ids.any?
        hm = HelpdeskMessage.where(:message_id => ref_ids).first
        return hm.issue if hm&.issue
      end

      nil
    end

    # Injiziert [#id] in den Betreff, wenn die Mail als Antwort auf eine bekannte
    # Helpdesk-Nachricht erkannt wird und der Betreff noch kein [#id]-Tag enthaelt.
    # Sichert die Thread-Zuordnung auch dann, wenn das Betreff geaendert wurde oder
    # der Autoresponder ohne [#id] konfiguriert ist.
    def ensure_thread_reference(mime)
      msg = Mail.read_from_string(mime)
      return mime if msg.subject.to_s =~ /\[#\d+\]/  # bereits vorhanden

      issue = find_referenced_issue(msg)
      return mime unless issue

      Rails.logger.info "Helpdesk (#{@mailbox.mailbox_address}): Thread-Referenz auf Ticket ##{issue.id} erkannt – [##{issue.id}] in Betreff injiziert"
      msg.subject = "[##{issue.id}] #{msg.subject}"
      msg.to_s
    rescue StandardError => e
      Rails.logger.warn "Helpdesk: ensure_thread_reference fehlgeschlagen: #{e.message}"
      mime
    end

    # Setzt den Status eines geschlossenen Tickets auf den konfigurierten Wiedereroeffnungs-Status.
    # Wird nur aufgerufen, wenn reopen_status_id am Postfach gesetzt ist.
    # Returns true when the ticket was actually reopened.
    #
    # save(validate: false) is deliberate and must stay: the ticket is mutated from
    # arbitrary inbound mail, and a field made mandatory, a workflow transition or a
    # locked version added since the ticket was created would otherwise make the save
    # fail silently -- leaving the ticket closed with the customer's reply inside it.
    def reopen_if_closed(issue, journal = nil)
      return false unless issue.status&.is_closed?
      return false if @mailbox.reopen_status_id.blank?

      reopen_status = IssueStatus.find_by(:id => @mailbox.reopen_status_id)
      return false unless reopen_status
      return false if reopen_status.id == issue.status_id

      old_status_id = issue.status_id
      issue.status = reopen_status
      issue.save(:validate => false)
      record_reopen_journal(issue, journal, old_status_id, reopen_status.id)
      Rails.logger.info "Helpdesk (#{@mailbox.mailbox_address}): Ticket ##{issue.id} wiedereroffnet \u2013 Status \"#{reopen_status.name}\""
      true
    end

    # Makes the auto-reopen visible in the ticket history. Because the status is set
    # without init_journal, Redmine writes no journal on its own.
    #
    # Preferred path: attach the status detail to the journal MailHandler just created
    # for the customer reply. That shows one history entry (note + status change)
    # instead of two, and creates no new Journal record -- so it cannot notify anyone.
    # Using issue.init_journal instead would arm Redmine's notification after_save and
    # could send mail, which this feature explicitly must not do.
    def record_reopen_journal(issue, journal, old_status_id, new_status_id)
      detail = {
        :property => 'attr', :prop_key => 'status_id',
        :old_value => old_status_id.to_s, :value => new_status_id.to_s
      }

      if journal&.persisted?
        JournalDetail.create!(detail.merge(:journal => journal))
      else
        fallback = Journal.new(:journalized => issue, :user => issue.author || User.anonymous)
        fallback.notify = false # Journal#after_create would mail the watchers otherwise
        fallback.details << JournalDetail.new(detail)
        fallback.save!
      end
    rescue StandardError => e
      Rails.logger.warn "Helpdesk: Wiedereroeffnungs-Journal fuer Ticket ##{issue.id} fehlgeschlagen: #{e.message}"
    end

    # True when the inbound mail was written by an agent (someone allowed to reply to
    # customers), so their own mail does not flag the ticket as waiting. Uses the same
    # definition of "agent" as the clear path in JournalPatch, which keeps setting and
    # clearing symmetric.
    def agent_authored?(object, issue)
      return false unless object.is_a?(Journal)

      user = object.user
      user.present? && user.allowed_to?(:send_helpdesk_reply, issue.project)
    rescue StandardError
      false
    end

    # --- Auto-Reply-Filter --------------------------------------------------

    # Prueft, ob die Mail als automatisch generierte Nachricht erkannt wurde
    # und vom Filter abgefangen werden soll.
    # Gibt false zurueck, wenn:
    #   - der Filter am Postfach deaktiviert ist
    #   - der Absender in der Absender-Whitelist steht
    #   - ein Header:Wert-Paar der Header-Whitelist in der Mail vorkommt
    def auto_reply_filtered?(mime, sender)
      return false unless @mailbox.auto_reply_filter_enabled?

      # Absender-Whitelist: dieser Absender soll auch mit Auto-Reply-Headern
      # verarbeitet werden (z. B. bekanntes Monitoring-System).
      sender_wl = parse_list(@mailbox.auto_reply_sender_whitelist)
      return false if sender_wl.any? && list_matches?(sender_wl, sender)

      begin
        msg = Mail.read_from_string(mime)
      rescue StandardError => e
        Rails.logger.warn "Helpdesk: Mail-Parse fuer Auto-Reply-Check fehlgeschlagen: #{e.message}"
        return false
      end

      # NDR-Erkennung vor dem eigentlichen Auto-Reply-Check.
      # RFC 3462: Delivery Status Notification hat immer report-type=delivery-status.
      # Exchange-spezifische Indikatoren als Fallback.
      if ndr_message?(msg)
        Rails.logger.info "Helpdesk (#{@mailbox.mailbox_address}): NDR erkannt, wird verarbeitet – CT=#{msg.content_type.inspect}"
        return false
      end

      trigger = auto_reply_trigger(msg)
      return false unless trigger

      Rails.logger.debug "Helpdesk: Auto-Reply-Trigger: #{trigger}"

      # Header-Whitelist: bestimmte Header:Wert-Paare heben den Filter auf.
      # Format je Zeile: "Header-Name: Wert" oder "Header-Name: *" fuer beliebigen Wert.
      return false if auto_reply_header_whitelist_matches?(msg)

      true
    end

    # Gibt eine kurze Beschreibung des auslösenden Auto-Reply-Headers zurück,
    # oder nil wenn kein Auto-Reply erkannt.
    def auto_reply_trigger(msg)
      auto_sub = msg['auto-submitted']&.value.to_s.strip.downcase
      return "auto-submitted: #{auto_sub}" if auto_sub.present? && auto_sub != 'no'

      val = msg['x-auto-response-suppress']&.value.to_s
      return "x-auto-response-suppress: #{val}" if val.present?

      val = msg['x-ms-exchange-generated-message-source']&.value.to_s
      return "x-ms-exchange-generated-message-source: #{val}" if val.present?

      %w[x-autorespond x-autoreply x-autoresponder].each do |h|
        val = msg[h]&.value.to_s
        return "#{h}: #{val}" if val.present?
      end

      prec = msg['precedence']&.value.to_s.strip.downcase
      return "precedence: #{prec}" if %w[bulk list junk].include?(prec)

      nil
    end

    # Erkennt NDR-/DSN-Nachrichten, die trotz Auto-Reply-Headern verarbeitet werden sollen.
    def ndr_message?(msg)
      # RFC 3462: multipart/report mit report-type=delivery-status (universell)
      ct = msg.content_type.to_s.downcase
      return true if ct.include?('report-type=delivery-status')

      # Exchange: X-MS-Exchange-Message-Is-Ndr ist gesetzt (Wert kann leer sein)
      return true unless msg['x-ms-exchange-message-is-ndr'].nil?
      return true if msg['x-ms-exchange-generated-message-source']&.value.to_s.strip.downcase == 'nondeliveryreport'

      false
    end

    # Entfernt Auto-Submitted-Header aus NDR-MIME, damit Redmines MailHandler
    # die Nachricht nicht als Auto-Reply ignoriert.
    def strip_auto_submitted_for_ndr(mime)
      msg = Mail.read_from_string(mime)
      return mime unless ndr_message?(msg)

      msg.header.fields.delete_if { |f| f.name.casecmp('auto-submitted').zero? }
      msg.to_s
    rescue StandardError => e
      Rails.logger.warn "Helpdesk: strip_auto_submitted_for_ndr fehlgeschlagen: #{e.message}"
      mime
    end

    # Prueft, ob ein Eintrag der Header-Whitelist des Postfachs in der Mail vorkommt.
    def auto_reply_header_whitelist_matches?(msg)
      parse_list(@mailbox.auto_reply_header_whitelist).any? do |entry|
        if entry.include?(':')
          header_name, expected = entry.split(':', 2).map(&:strip)
          actual = msg[header_name.downcase]&.value.to_s.strip
          expected == '*' ? actual.present? : actual.casecmp(expected).zero?
        else
          msg[entry.downcase.strip]&.value.to_s.present?
        end
      end
    end

    # --- Black-/Whitelist ---------------------------------------------------

    # Eintraege (eine Adresse oder Domain pro Zeile). Whitelist gewinnt:
    # Ist eine Whitelist gepflegt, sind nur deren Absender erlaubt.
    def sender_rejected?(sender)
      allow = parse_list(@mailbox.allow_list)
      deny  = parse_list(@mailbox.deny_list)

      return true if allow.any? && !list_matches?(allow, sender)
      return true if deny.any? && list_matches?(deny, sender)

      false
    end

    def parse_list(text)
      text.to_s.split(/[\r\n,;]+/).map { |e| e.strip.downcase }.reject(&:blank?)
    end

    def list_matches?(entries, sender)
      domain = sender.split('@').last.to_s
      entries.any? { |e| e == sender || e == domain || e == "@#{domain}" }
    end

    # --- Regeln ---------------------------------------------------------------

    def ignore_rule_matches?(subject, sender)
      @mailbox.helpdesk_rules.where(:action_type => 'ignore').any? do |rule|
        rule.matches?(subject, sender)
      end
    end

    # New tickets only: first the project's default assignee, then the mailbox
    # rules - a matching rule is the more specific statement and may override
    # the default.
    def apply_new_issue_defaults(issue, subject, sender)
      # Ticket neu laden, damit lock_version aktuell ist (MailHandler speichert das
      # Ticket mehrfach, was zu StaleObjectError fuehrt, wenn wir die veraltete
      # In-Memory-Instanz speichern wuerden).
      issue.reload
      changed = apply_default_assignee(issue)
      @mailbox.helpdesk_rules.where.not(:action_type => 'ignore').order(:position).each do |rule|
        next unless rule.matches?(subject, sender)

        changed = true if rule.apply_to(issue)
      end
      issue.save(:validate => false) if changed
    end

    # Only when nobody is assigned yet: MailHandler may already have honoured an
    # "Assigned to:" keyword from the mail, and that wins over the project default.
    def apply_default_assignee(issue)
      return false if issue.assigned_to_id.present?

      assignee = project_setting.default_assignee
      return false unless assignee

      issue.assigned_to = assignee
      true
    end

    # --- Phishing-Pruefung ----------------------------------------------------

    # Aktiv wenn: global eingeschaltet + im Projekt aktiviert + Spiegel nicht leer.
    # Loggt den Grund, wenn die Pruefung uebersprungen wird.
    def phishing_check_enabled?
      unless Setting.plugin_redmine_expert_helpdesk['phishtank_enabled'] == '1'
        Rails.logger.info "Helpdesk/Phishing (#{@mailbox.mailbox_address}): Pruefung uebersprungen – global deaktiviert"
        return false
      end
      unless project_setting.phishing_check_enabled?
        Rails.logger.info "Helpdesk/Phishing (#{@mailbox.mailbox_address}): Pruefung uebersprungen – im Projekt '#{@mailbox.project.identifier}' deaktiviert"
        return false
      end
      unless HelpdeskPhishingUrl.exists?
        Rails.logger.warn "Helpdesk/Phishing (#{@mailbox.mailbox_address}): Pruefung uebersprungen – PhishTank-Spiegel ist leer"
        return false
      end

      Rails.logger.info "Helpdesk/Phishing (#{@mailbox.mailbox_address}): Pruefung aktiv (Aktion: #{phishing_action})"
      true
    end

    def phishing_action
      project_setting.effective_phishing_action
    end

    def project_setting
      @project_setting ||= HelpdeskProjectSetting.for_project(@mailbox.project)
    end

    # Interne Notiz am Ticket: welche Phishing-URLs neutralisiert und welche
    # verschleierten Links markiert wurden.
    def add_phishing_note(issue, hits, suspicions = [])
      sections = []

      if hits.any?
        lines = hits.map do |h|
          detail = h[:target].present? ? " (Ziel: #{h[:target]})" : ''
          resolved = h[:resolved_url].present? ? " -> #{h[:resolved_url]}" : ''
          "* #{h[:url]}#{resolved} – #{h[:source_label]}#{detail}"
        end
        sections << "#{I18n.t(:note_helpdesk_phishing_links_removed, :count => hits.size)}\n\n#{lines.join("\n")}"
      end

      if suspicions.any?
        lines = suspicions.map { |s| "* #{s[:url]} – #{s[:label]}" }
        sections << "#{I18n.t(:note_helpdesk_phishing_suspicions, :count => suspicions.size)}\n\n#{lines.join("\n")}"
      end

      Journal.create!(
        :journalized   => issue,
        :user          => User.anonymous,
        :notes         => sections.join("\n\n"),
        :private_notes => false
      )
    rescue StandardError => e
      Rails.logger.error "Helpdesk: Phishing-Notiz fuer Ticket ##{issue.id} fehlgeschlagen: #{e.message}"
    end

    # --- Autoresponder --------------------------------------------------------

    def send_autoresponder(issue, contact, in_reply_to_message_id = nil)
      body = TemplateRenderer.render(@mailbox.autoresponder_body, :issue => issue, :contact => contact)
      subject = TemplateRenderer.render(
        @mailbox.autoresponder_subject.presence || "[##{issue.id}] {{ticket_subject}}",
        :issue => issue, :contact => contact
      )

      # MIME aufbauen, damit In-Reply-To / References gesetzt werden koennen.
      # Microsoft Graph lehnt diese Header bei JSON-Anfragen (sendMail) mit HTTP 400 ab.
      # Durch die References-Verknuepfung mit der urspruenglichen Kundenmail erkennt
      # Redmines MailHandler Antworten auf den Autoresponder und ordnet sie dem Ticket zu.
      mail = Mail.new
      mail.from    = @mailbox.from_address
      # Opt-in only; see HelpdeskMailbox#reply_to_address.
      reply_to_addr = @mailbox.reply_to_address
      mail.reply_to = reply_to_addr if reply_to_addr
      mail.to      = contact.email
      mail.subject = subject
      mail.body    = body

      if in_reply_to_message_id.present?
        ref_id = "<#{in_reply_to_message_id.to_s.delete('<>').strip}>"
        mail['In-Reply-To'] = ref_id
        mail['References']  = ref_id
      end

      MailLogger.track(
        :kind => 'autoresponder', :mailbox => @mailbox, :issue => issue,
        :to => contact.email, :subject => subject, :message_id => mail.message_id
      ) { deliver_autoresponder(mail) }

      HelpdeskMessage.create!(
        :issue => issue, :helpdesk_contact => contact, :helpdesk_mailbox => @mailbox,
        :direction => 'out', :subject => subject, :sent_at => Time.current
      )

      # Interne Notiz: Autoresponder-Versand im Ticket-Journal vermerken
      Journal.create!(
        :journalized   => issue,
        :user          => User.anonymous,
        :notes         => I18n.t(:note_helpdesk_autoresponder_sent, :email => contact.email),
        :private_notes => false
      )
    rescue MailProvider::ProviderError => e
      Rails.logger.error "Helpdesk: Autoresponder fuer Ticket ##{issue.id} fehlgeschlagen: #{e.message}"
    end

    # The autoresponder takes the mailbox's outgoing route like every other
    # outgoing mail: 'smtp' hands the message to Redmine's own ActionMailer
    # configuration, everything else goes through a provider.
    def deliver_autoresponder(mail)
      if @mailbox.outgoing_route == 'smtp'
        mail.delivery_method(ActionMailer::Base.delivery_method,
                             ActionMailer::Base.smtp_settings || {})
        mail.deliver!
        # Redmine's relay files nothing in the mailbox, so archive it ourselves.
        @provider.archive_sent(mail.to_s)
      else
        autoresponder_provider.send_mail_mime(mail.to_s)
      end
    end

    # Reuse the injected fetch provider where it is also the sender, so tests can
    # keep driving the whole cycle through one double.
    def autoresponder_provider
      return @provider if @mailbox.outgoing_route == 'mailbox_smtp'

      MailProvider.outgoing_for(@mailbox)
    end

    def move_processed(message_id)
      @provider.mark_as_read(message_id)
      return if @mailbox.processed_folder.blank?

      @provider.move_message(message_id, @mailbox.processed_folder)
    end

    # Uebersprungene Mails (Blacklist, Ignorier-Regel, Auto-Reply) in den
    # konfigurierten Ordner verschieben. Fallback: processed_folder.
    def move_skipped(message_id)
      @provider.mark_as_read(message_id)
      target = @mailbox.skipped_folder.presence || @mailbox.processed_folder.presence
      return if target.blank?

      @provider.move_message(message_id, target)
    end

    # Fehlgeschlagene Mails (Exception waehrend der Verarbeitung) in den
    # konfigurierten Ordner verschieben. Fallback: processed_folder.
    def move_failed(message_id)
      @provider.mark_as_read(message_id)
      target = @mailbox.failed_folder.presence || @mailbox.processed_folder.presence
      return if target.blank?

      @provider.move_message(message_id, target)
    end

    # Haengt die originale Mail als .eml-Datei an das Ticket an.
    # Verwendet StringIO um Probleme mit Tempfile-Lebensdauer zu vermeiden.
    # Liefert das gespeicherte Attachment-Objekt oder nil bei Fehler.
    def attach_eml(issue, mime, author)
      filename = "original_mail_#{Time.current.strftime('%Y%m%d_%H%M%S')}.eml"

      # Sicherstellen, dass die Bytes unveraendert als Binary gespeichert werden
      raw = mime.dup.force_encoding('BINARY')
      io  = StringIO.new(raw)
      io.define_singleton_method(:original_filename) { filename }
      io.define_singleton_method(:content_type)      { 'application/octet-stream' }

      att = Attachment.new(
        :container   => issue,
        :file        => io,
        :description => 'Original E-Mail',
        :author      => author
      )
      att.save!
      att
    rescue StandardError => e
      Rails.logger.warn "Helpdesk: EML-Anhang fuer Ticket ##{issue.id} fehlgeschlagen: #{e.message}\n#{e.backtrace.first(3).join('\n')}"
      nil
    end
  end
end
