# Einfacher Template-Renderer fuer Autoresponder und Kundenantworten.
#
# Unterstuetzte Makros (beide Schreibweisen werden akzeptiert):
#   {{issue.id}} / {{ticket_id}}         – Ticket-Nummer
#   {{issue.subject}} / {{ticket_subject}} – Ticket-Titel
#   {{issue.url}} / {{ticket_url}}         – Link zum Ticket
#   {{contact.name}} / {{contact_name}}   – Name des Kunden
#   {{contact.email}} / {{contact_email}} – E-Mail des Kunden
#   {{user.name}} / {{user_name}}         – Antwortender Benutzer
#   {{project.name}} / {{project_name}}   – Projektname

module RedmineExpertHelpdesk
  class TemplateRenderer
    def self.render(template, context = {})
      return '' if template.blank?

      issue   = context[:issue]
      contact = context[:contact]
      user    = context[:user]

      id_str      = issue ? issue.id.to_s : ''
      subject_str = issue ? issue.subject.to_s : ''
      url_str     = issue ? issue_url(issue) : ''
      contact_name  = contact ? contact.display_name : context[:contact_name].to_s
      contact_email = contact ? contact.email.to_s : context[:contact_email].to_s
      user_name     = user ? user.name : ''
      project_name  = issue&.project ? issue.project.name : ''

      replacements = {
        # Punkt-Notation (aus Projekteinstellungen)
        'issue.id'      => id_str,
        'issue.subject' => subject_str,
        'issue.url'     => url_str,
        'contact.name'  => contact_name,
        'contact.email' => contact_email,
        'user.name'     => user_name,
        'project.name'  => project_name,
        # Legacy-Notation (Autoresponder-Templates)
        'ticket_id'      => id_str,
        'ticket_subject' => subject_str,
        'ticket_url'     => url_str,
        'contact_name'   => contact_name,
        'contact_email'  => contact_email,
        'user_name'      => user_name,
        'project_name'   => project_name
      }

      # Regex erlaubt Buchstaben, Ziffern, Unterstrich und Punkt (fuer dot-notation)
      template.gsub(/\{\{([\w.]+)\}\}/) { replacements.fetch(Regexp.last_match(1), '') }
    end

    def self.issue_url(issue)
      host = Setting.host_name.to_s.sub(%r{/+$}, '')
      "#{Setting.protocol}://#{host}/issues/#{issue.id}"
    end
  end
end
