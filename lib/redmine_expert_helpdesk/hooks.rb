# View-Hooks: Kundenkarte in der Seitenleiste, Info-Leiste im Ticket-Kopf und Antwortformular
module RedmineExpertHelpdesk
  class Hooks < Redmine::Hook::ViewListener
    # Stylesheet fuer Aktivitaets-Feed-Icons (eingehend/ausgehend/Erstkontakt) in den <head> einfuegen.
    # Ab Redmine 6 zusaetzlich einen JS-Helfer bereitstellen, der SVG-Sprite-Icons erzeugt
    # (die alten `icon icon-*`-CSS-Klassen wurden in Redmine 7 entfernt). So koennen auch per
    # JavaScript erzeugte Elemente (Antwort-Button, Seitenleiste) korrekt Icons anzeigen.
    def view_layouts_base_html_head(context = {})
      out = stylesheet_link_tag('helpdesk_activity', :plugin => 'redmine_expert_helpdesk')
      if Redmine::VERSION::MAJOR >= 6
        sprite = asset_path('icons.svg')
        out << javascript_tag(
          "window.hdIconsSprite=#{sprite.to_json};" \
          "window.hdSpriteIcon=function(n){return '<svg class=\"s18 icon-svg\" aria-hidden=\"true\">'+" \
          "'<use href=\"'+window.hdIconsSprite+'#icon--'+n+'\"></use></svg>';};"
        )
      end
      out
    end

    # Info-Leiste am Ticket-Kopf (unterhalb der Felder, kein Deface erforderlich).
    # view_issues_show_details_bottom wird innerhalb von <div class="attributes"> gerendert.
    # Zeigt Kontaktinfo auch wenn das erste Ticket ausgehend war (manuell zugeordnet).
    def view_issues_show_details_bottom(context = {})
      issue = context[:issue]
      return '' unless issue

      project = issue.project
      return '' unless project.module_enabled?(:helpdesk)
      return '' unless User.current.allowed_to?(:view_helpdesk_info, project)

      parts = []

      # SLA-Box (unabhaengig vom Kundenkontakt)
      sla_state = RedmineExpertHelpdesk::Sla.state_for(issue)
      if sla_state && (sla_state[:reaction] || sla_state[:solution])
        parts << context[:controller].send(:render_to_string, {
          :partial => 'helpdesk/sla_box',
          :locals  => { :sla_state => sla_state }
        })
      end

      contact = HelpdeskTicketInfo.for_issue(issue)&.helpdesk_contact
      if contact
        # inbound ist nil wenn kein eingehendes Ticket existiert (manuell/ausgehend)
        inbound = HelpdeskMessage.incoming.includes(:eml_attachment)
                                 .where(:issue_id => issue.id)
                                 .order(:id => :asc).first

        # Erstkontakt ausgehend ("Neues Helpdesk-Ticket"): initiale Mail anzeigen
        outbound = nil
        if inbound.nil?
          outbound = HelpdeskMessage.where(:issue_id => issue.id, :direction => %w[out init])
                                    .order(:id => :asc).first
        end

        parts << context[:controller].send(:render_to_string, {
          :partial => 'helpdesk/issue_header_bar',
          :locals  => {
            :issue    => issue,
            :inbound  => inbound,
            :outbound => outbound,
            :contact  => contact
          }
        })
      end

      parts.join.html_safe
    end

    # Kundenkarte in der Ticket-Seitenleiste (nach den Suchabfragen)
    # Wird auf der Issue-Show-Seite UND der Issue-Liste ausgefuehrt;
    # Guard auf @issue stellt sicher, dass nur die Show-Seite gerendert wird.
    # Zeigt Kontaktinfo auch fuer manuell/ausgehend zugeordnete Tickets.
    def view_issues_sidebar_queries_bottom(context = {})
      issue = context[:controller]&.instance_variable_get(:@issue)
      return '' unless issue

      project = issue.project
      return '' unless project.module_enabled?(:helpdesk)

      contact = HelpdeskTicketInfo.for_issue(issue)&.helpdesk_contact

      if contact.nil?
        # Kein Kontakt: Zuordnungsformular in der Seitenleiste anzeigen
        return '' unless User.current.allowed_to?(:send_helpdesk_reply, project)
        mailboxes = project.helpdesk_mailboxes.enabled.to_a
        return '' if mailboxes.empty?
        return context[:controller].send(:render_to_string, {
          :partial => 'helpdesk/init_section',
          :locals  => {
            :issue       => issue,
            :project     => project,
            :mailboxes   => mailboxes,
            :in_new_form => false
          }
        })
      end

      # Kontakt vorhanden: Kundenkarte anzeigen
      return '' unless User.current.allowed_to?(:view_helpdesk_info, project)

      outgoing_msgs = HelpdeskMessage.outgoing
                                     .where(:issue_id => issue.id)
                                     .where.not(:recipient_to => [nil, ''])
                                     .select(:id, :journal_id, :sent_at, :recipient_to, :recipient_cc, :recipient_bcc, :sent_attachments)

      context[:controller].send(:render_to_string, {
        :partial => 'helpdesk/issue_sidebar',
        :locals  => {
          :issue         => issue,
          :contact       => contact,
          :project       => project,
          :outgoing_msgs => outgoing_msgs
        }
      })
    end

    # Antwortformular ("Als Mail an Kunden senden") im Bearbeitungsformular.
    # Kein Kontakt zugeordnet: Zuordnungsformular erscheint in der Seitenleiste (view_issues_sidebar_queries_bottom).
    def view_issues_edit_notes_bottom(context = {})
      issue = context[:issue]
      project = issue.project
      return '' unless project.module_enabled?(:helpdesk)
      return '' unless User.current.allowed_to?(:send_helpdesk_reply, project)

      info    = HelpdeskTicketInfo.for_issue(issue)
      contact = info&.helpdesk_contact
      return '' if contact.nil?  # Zuordnungsformular wird in der Seitenleiste angezeigt

      # Kontakt gefunden: Antwortformular rendern
      mailbox = info.helpdesk_mailbox&.enabled? ? info.helpdesk_mailbox : nil
      mailbox ||= project.helpdesk_mailboxes.enabled.first

      ctx = { :issue => issue, :contact => contact, :user => User.current }
      footer_text = mailbox ?
        RedmineExpertHelpdesk::TemplateRenderer.render(mailbox.effective_footer_template, ctx) : ''

      project_setting  = HelpdeskProjectSetting.for_project(project)
      send_by_default  = project_setting.send_reply_by_default

      context[:controller].send(:render_to_string, {
        :partial => 'helpdesk/reply_in_edit',
        :locals  => {
          :issue                  => issue,
          :contact                => contact,
          :project                => project,
          :footer_text            => footer_text.to_s,
          :send_by_default        => send_by_default,
          :reply_status_id        => project_setting.reply_status_id,
          :reply_assign_to_sender => project_setting.reply_assign_to_sender
        }
      })
    end

    # "Helpdesk-Ticket erstellen"-Sektion im neuen Ticket-Formular.
    # Ermoeglicht das Versenden einer initialen Mail direkt beim Anlegen des Tickets.
    def view_issues_form_details_bottom(context = {})
      issue = context[:issue]
      return '' unless issue.new_record?

      project = issue.project
      return '' unless project&.module_enabled?(:helpdesk)
      return '' unless User.current.allowed_to?(:send_helpdesk_reply, project)

      mailboxes = project.helpdesk_mailboxes.enabled.to_a
      return '' if mailboxes.empty?

      context[:controller].send(:render_to_string, {
        :partial => 'helpdesk/init_section',
        :locals  => {
          :issue       => issue,
          :project     => project,
          :mailboxes   => mailboxes,
          :in_new_form => true
        }
      })
    end

    # Controller-Hook: verknuepft Kundenkontakt und sendet optional initiale Mail nach
    # dem Erstellen eines neuen Tickets, wenn helpdesk_init-Parameter uebergeben wurden.
    def controller_issues_new_after_save(context = {})
      issue  = context[:issue]
      params = context[:params]

      hd = params[:helpdesk_init]
      return unless hd.present?
      return unless issue.project.module_enabled?(:helpdesk)
      return unless User.current.allowed_to?(:send_helpdesk_reply, issue.project)

      to_list = hd[:contact_email].to_s.split(/[,;]/).map { |a| a.strip.downcase }.reject(&:blank?)
      return unless to_list.first.to_s.match?(/\A[^@\s]+@[^@\s]+\z/)

      mailbox = issue.project.helpdesk_mailboxes.enabled.find_by(:id => hd[:mailbox_id].to_i) ||
                issue.project.helpdesk_mailboxes.enabled.first
      return unless mailbox

      RedmineExpertHelpdesk::InitMailer.call(
        :issue         => issue,
        :contact_email => to_list.join(', '),
        :contact_name  => hd[:contact_name].to_s.strip.presence,
        :cc            => hd[:cc].to_s,
        :bcc           => hd[:bcc].to_s,
        :mailbox       => mailbox,
        :user          => User.current,
        :send_mail     => hd[:send_mail] == '1'
      )
    rescue StandardError => e
      Rails.logger.error("Helpdesk InitMailer (new issue): #{e.message}\n#{e.backtrace.first(3).join("\n")}")
    end

    # Controller-Hook: verknuepft das beim Issue-Update erstellte Journal mit der
    # zuvor per AJAX versendeten Kundenantwort (HelpdeskMessage). Die Message-ID
    # wird vom Antwortformular als Hidden-Field mitgeschickt (deterministisch,
    # kein Timestamp-Matching). Zusaetzlich: SLA-Tracking (erste Reaktion,
    # Loesungszeit beim Schliessen, Reset beim Wiedereroeffnen).
    def controller_issues_edit_after_save(context = {})
      journal = context[:journal]
      issue   = context[:issue]
      msg_id  = context[:params] && context[:params][:hd_sent_message_id].presence

      if journal && msg_id
        msg = HelpdeskMessage.outgoing.find_by(:id => msg_id.to_i, :issue_id => journal.journalized_id, :journal_id => nil)
        msg&.update_column(:journal_id, journal.id)
      end

      # SLA: oeffentlicher Kommentar eines Mitarbeiters stoppt die Reaktionsuhr
      if issue && journal && journal.notes.present? && !journal.private_notes?
        RedmineExpertHelpdesk::Sla.record_first_response!(issue, journal.created_on || Time.current)
      end

      # SLA: Loesungszeit beim Schliessen setzen / beim Wiedereroeffnen zuruecksetzen
      RedmineExpertHelpdesk::Sla.sync_solution!(issue) if issue&.saved_change_to_status_id?
    rescue StandardError => e
      Rails.logger.warn("Helpdesk: edit_after_save-Hook fehlgeschlagen: #{e.message}")
    end

    # Button "Neues Helpdesk-Ticket" in der Ticket-Liste (neben "Neues Ticket").
    # Wird per JavaScript in den Kontextbereich eingefuegt.
    def view_issues_index_bottom(context = {})
      project = context[:project]
      return '' unless project&.module_enabled?(:helpdesk)
      return '' unless User.current.allowed_to?(:send_helpdesk_reply, project)
      return '' if project.helpdesk_mailboxes.enabled.none?

      new_url   = context[:controller].send(:new_project_issue_path, project, :helpdesk_init => '1')
      btn_label = I18n.t(:button_helpdesk_new_ticket)

      %(<script>
//<![CDATA[
(function() {
  var ctx = document.querySelector('#content > div.contextual');
  if (!ctx) return;
  var a = document.createElement('a');
  a.href      = #{new_url.to_json};
  a.className = 'icon icon-email';
  a.style.marginRight = '6px';
  a.textContent = #{btn_label.to_json};
  ctx.insertBefore(a, ctx.firstChild);
})();
//]]>
</script>)
    end
  end
end
