# Benachrichtigung bei SLA-Ueberschreitung (an Eskalationsadresse / Projekt-User).
class HelpdeskSlaMailer < Mailer
  def sla_breach(recipients, issue, breached_clocks, state)
    @issue   = issue
    @clocks  = breached_clocks
    @state   = state

    mail :to      => recipients,
         :subject => "[SLA] ##{issue.id} #{issue.subject.to_s.truncate(60)}: #{I18n.t(:mail_subject_helpdesk_sla_breach)}"
  end

  def self.deliver_sla_breach(recipients, issue, breached_clocks, state)
    sla_breach(recipients, issue, breached_clocks, state).deliver_later
  end
end
