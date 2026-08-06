# Central log for every mail this plugin sends.
#
# Outgoing mail leaves the plugin through three different transports (Graph
# sendMail, the mailbox's own SMTP server, Redmine's global ActionMailer SMTP)
# and from four different places (agent reply, initial mail, autoresponder, SLA
# breach notification). When a customer says "I never got that mail", the log
# has to answer *which way* it was sent, not just that something happened - so
# every send site funnels through here and the route is always part of the line.
#
# Success is logged at the level configured in the plugin settings
# ('mail_log_level', default 'info'); failures are always logged at error level.
module RedmineExpertHelpdesk
  module MailLogger
    PREFIX = '[helpdesk]'.freeze

    # Severities offered in the settings form. 'debug' keeps the line out of a
    # production log (Redmine defaults to :info there), 'warn'/'error' pull it
    # into installations that only keep warnings.
    LEVELS = %w[debug info warn error].freeze
    DEFAULT_LEVEL = 'info'.freeze

    # Human-readable transport names - these end up in the log line verbatim.
    ROUTE_LABELS = {
      'graph'        => 'Microsoft Graph sendMail',
      'mailbox_smtp' => 'mailbox SMTP',
      'smtp'         => 'Redmine SMTP (ActionMailer)',
      'actionmailer' => 'Redmine ActionMailer'
    }.freeze

    class << self
      # Wraps an actual send. Logs one line on success, one at error level when
      # the send raises - and re-raises, so callers keep their own handling.
      #
      #   MailLogger.track(:kind => 'reply', :mailbox => mailbox, :to => to) do
      #     provider.send_mail_mime(mime)
      #   end
      def track(kind:, mailbox: nil, route: nil, to: nil, cc: nil, bcc: nil,
                subject: nil, message_id: nil, issue: nil, detail: nil)
        result = yield
        sent(:kind => kind, :mailbox => mailbox, :route => route, :to => to, :cc => cc,
             :bcc => bcc, :subject => subject, :message_id => message_id,
             :issue => issue, :detail => detail)
        result
      rescue StandardError => e
        failed(:kind => kind, :mailbox => mailbox, :route => route, :to => to, :cc => cc,
               :bcc => bcc, :subject => subject, :message_id => message_id,
               :issue => issue, :detail => detail, :error => e)
        raise
      end

      def sent(kind:, mailbox: nil, route: nil, to: nil, cc: nil, bcc: nil,
               subject: nil, message_id: nil, issue: nil, detail: nil)
        log(level, "#{PREFIX} mail sent: " + fields(kind, mailbox, route, to, cc, bcc,
                                                    subject, message_id, issue, detail).join(' '))
      end

      def failed(kind:, mailbox: nil, route: nil, to: nil, cc: nil, bcc: nil,
                 subject: nil, message_id: nil, issue: nil, detail: nil, error: nil)
        parts = fields(kind, mailbox, route, to, cc, bcc, subject, message_id, issue, detail)
        parts << "error=#{quote("#{error.class}: #{error.message}")}" if error
        log('error', "#{PREFIX} mail FAILED: #{parts.join(' ')}")
      end

      # Resolves the route for a mailbox and describes the concrete endpoint,
      # e.g. "mailbox SMTP (smtp.example.com:587)".
      def route_label(route, mailbox = nil)
        route ||= mailbox&.outgoing_route
        label = ROUTE_LABELS[route.to_s] || route.to_s.presence || 'unknown'

        case route.to_s
        when 'mailbox_smtp'
          host = mailbox&.smtp_host.presence
          host ? "#{label} (#{host}:#{smtp_port(mailbox)})" : label
        when 'smtp', 'actionmailer'
          host = (ActionMailer::Base.smtp_settings || {})[:address]
          host.present? ? "#{label} (#{host})" : label
        else
          label
        end
      rescue StandardError
        label || 'unknown'
      end

      def level
        configured = Setting.plugin_redmine_expert_helpdesk['mail_log_level'].to_s
        LEVELS.include?(configured) ? configured : DEFAULT_LEVEL
      rescue StandardError
        DEFAULT_LEVEL
      end

      private

      def fields(kind, mailbox, route, to, cc, bcc, subject, message_id, issue, detail)
        parts = []
        parts << "kind=#{kind}"
        parts << "via=#{quote(route_label(route, mailbox))}"
        parts << "mailbox=#{mailbox.mailbox_address}" if mailbox.respond_to?(:mailbox_address)
        parts << "project=#{mailbox.project&.identifier}" if mailbox.respond_to?(:project) && mailbox.project
        parts << "issue=##{issue_id(issue)}" if issue
        parts << "to=#{quote(addresses(to))}" if present?(to)
        parts << "cc=#{quote(addresses(cc))}" if present?(cc)
        parts << "bcc=#{quote(addresses(bcc))}" if present?(bcc)
        parts << "message_id=#{message_id}" if message_id.present?
        parts << "subject=#{quote(subject.to_s.truncate(120))}" if subject.present?
        parts << detail.to_s if detail.present?
        parts
      end

      def issue_id(issue)
        issue.respond_to?(:id) ? issue.id : issue
      end

      def addresses(value)
        Array(value).flatten.map(&:to_s).reject(&:blank?).join(', ')
      end

      def present?(value)
        addresses(value).present?
      end

      def quote(value)
        %("#{value.to_s.gsub(/\s+/, ' ').gsub('"', "'")}")
      end

      def smtp_port(mailbox)
        mailbox.smtp_port.presence || (mailbox.smtp_security.to_s == 'ssl' ? 465 : 587)
      end

      def log(severity, message)
        logger = Rails.logger
        return unless logger

        logger.public_send(severity, message)
      rescue StandardError
        nil
      end
    end
  end
end
