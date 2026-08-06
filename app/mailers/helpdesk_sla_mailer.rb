# Benachrichtigung bei SLA-Ueberschreitung (an Eskalationsadresse / Projekt-User).
class HelpdeskSlaMailer < Mailer
  def sla_breach(recipients, issue, breached_clocks, state)
    @issue   = issue
    @clocks  = breached_clocks
    @state   = state

    mail :to      => recipients,
         :subject => "[SLA] ##{issue.id} #{issue.subject.to_s.truncate(60)}: #{I18n.t(:mail_subject_helpdesk_sla_breach)}"
  end

  # SLA notifications are internal mail and go through Redmine's own mailer, not
  # through a helpdesk mailbox - the log line says so, and that it was queued
  # rather than handed to the server synchronously.
  def self.deliver_sla_breach(recipients, issue, breached_clocks, state)
    RedmineExpertHelpdesk::MailLogger.track(
      :kind => 'sla_breach', :route => 'actionmailer', :issue => issue,
      :to => recipients, :detail => 'queued=deliver_later'
    ) do
      sla_breach(recipients, issue, breached_clocks, state).deliver_later
    end
  end
end
