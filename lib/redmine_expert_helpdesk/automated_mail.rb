# Detection of machine-generated mail from the message headers (RFC 3834 and the
# de-facto headers Exchange and the common autoresponders add).
#
# Two callers with opposite intentions share this:
# - MailProcessor drops auto-replies before they become tickets.
# - HelpdeskCompletenessJob keeps the ticket but asks nobody for more information -
#   a Veeam job report or a cron mail has no author who could answer.
#
# Both need the same answer to "did a human write this", so the header list lives
# in one place. NDR/DSN is deliberately NOT automated mail here: a bounce carries
# auto-reply headers but is a delivery failure the plugin has to act on.
module RedmineExpertHelpdesk
  class AutomatedMail
    class << self
      def automated?(msg)
        trigger(msg).present?
      end

      # A short description of the header that triggered, or nil when the mail
      # looks hand-written. The description is for the log - it is the only way to
      # tell a filtered mail from one that was never checked.
      def trigger(msg)
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

      # NDR/DSN messages, which carry auto-reply headers but must still be processed.
      def ndr?(msg)
        # RFC 3462: multipart/report with report-type=delivery-status (universal).
        ct = msg.content_type.to_s.downcase
        return true if ct.include?('report-type=delivery-status')

        # Exchange: X-MS-Exchange-Message-Is-Ndr is set (the value may be empty).
        return true unless msg['x-ms-exchange-message-is-ndr'].nil?

        msg['x-ms-exchange-generated-message-source']&.value.to_s.strip.downcase ==
          'nondeliveryreport'
      end

      # Sender matching for the black-/whitelists: full address, bare domain or
      # "@domain". Entries and sender are compared downcased.
      def parse_list(text)
        text.to_s.split(/[\r\n,;]+/).map { |e| e.strip.downcase }.reject(&:blank?)
      end

      def list_matches?(entries, sender)
        address = sender.to_s.strip.downcase
        domain  = address.split('@').last.to_s

        entries.any? { |e| e == address || e == domain || e == "@#{domain}" }
      end
    end
  end
end
