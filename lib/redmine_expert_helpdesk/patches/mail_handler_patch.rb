module RedmineExpertHelpdesk
  module Patches
    # Redmine's MailHandler drops every mail whose sender has an account that is
    # not active (locked, or registered and never activated) and says so only at
    # info level. Staff whose Redmine login was locked long ago still write to
    # the helpdesk, and a mailbox that takes mail from complete strangers
    # (unknown_user 'accept' or 'create') then silently loses theirs. RedmineUP's
    # helpdesk, which received these mailboxes before, never checked the status.
    #
    # With the handler option :accept_inactive_sender the mail is received on
    # that account instead, as RedmineUP did: the ticket or note carries the
    # person's name rather than "Anonymous". Without the option MailHandler
    # behaves exactly as in core.
    #
    # Core's receive has no hook between the user lookup and the status check,
    # so the two checks that run before it are repeated here (mail from Redmine's
    # own address, auto-generated mail); for those, and for every sender that is
    # not an inactive account, core's own receive runs. The method is unchanged
    # from Redmine 5.0 to 7 - test/unit/mail_handler_inactive_sender_test.rb pins
    # that core still drops these senders without the option.
    module MailHandlerPatch
      def receive(email, options = {})
        return super unless options[:accept_inactive_sender]

        sender_email = email.from.to_a.first.to_s.strip
        user = User.find_by_mail(sender_email) if sender_email.present?
        return super if user.nil? || user.active?
        return super if MailHandlerPatch.ignored_before_user_lookup?(email, sender_email)

        @email = email
        @handler_options = options
        @user = user
        logger&.info "MailHandler: accepting email from non-active user [#{user.login}] (helpdesk)"
        User.current = @user
        dispatch
      end

      # Core's checks before the user lookup, without its logging: true when
      # MailHandler drops the mail whoever sent it.
      def self.ignored_before_user_lookup?(email, sender_email)
        emission_address?(sender_email) || auto_generated?(email)
      end

      def self.emission_address?(sender_email)
        emission_address = Setting.mail_from.to_s.gsub(/(?:.*<|>.*|\(.*\))/, '').strip
        sender_email.to_s.strip.casecmp(emission_address).zero?
      end

      def self.auto_generated?(email)
        MailHandler.ignored_emails_headers.any? do |key, ignored_value|
          value = email.header[key]
          next false unless value

          value = value.to_s.downcase
          (ignored_value.is_a?(Regexp) && ignored_value.match?(value)) || value == ignored_value
        end
      end
    end
  end
end
