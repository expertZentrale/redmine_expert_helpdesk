# Hand-over of a ticket to another project, without a mail (experimental).
#
# An agent who puts the helpdesk address of another project into a reply wants
# that project to take the topic on. Mailing it there sends the conversation
# through SMTP and IMAP only to be turned back into a ticket - and the copy
# carries the source ticket's thread markers, which the receiving mailbox then
# has to strip again (see ThreadScope). When both projects take part in
# hand-overs, the reply controller removes such addresses from the mail and
# creates the ticket in the other project directly.
#
# The agent chooses what goes over:
#   note    - the reply text with the attachments sent along with it
#   history - additionally the ticket's description and public notes, and all
#             of its attachments. Private notes stay behind: they were written
#             for the source team only.
#
# Switched on centrally (plugin setting handover_enabled) *and* per project
# (HelpdeskProjectSetting#handover_enabled); a hand-over needs the source and
# the target project to take part, so each team decides for itself.
module RedmineExpertHelpdesk
  class Handover
    MODES = %w[note history].freeze

    class Error < StandardError; end

    def self.enabled?(settings = Setting.plugin_redmine_expert_helpdesk)
      settings['handover_enabled'].to_s == '1'
    end

    def self.project_enabled?(project)
      return false unless enabled? && project&.active? && project.module_enabled?(:helpdesk)

      setting = HelpdeskProjectSetting.for_project(project)
      setting.has_attribute?(:handover_enabled) && setting.handover_enabled? ? true : false
    end

    # The mailboxes a ticket of +project+ can be handed over to, keyed by their
    # address in lower case. Only projects +user+ can see: the list is shipped
    # to the reply form, and an address of a project the agent cannot see is
    # none of their business - to them it stays an ordinary recipient.
    def self.targets_for(project, user = User.current)
      return {} unless project_enabled?(project)

      # One query: settings looked up per mailbox cost a query for every
      # project with a helpdesk, on every ticket page and reply.
      participating = Project.active.has_module(:helpdesk).visible(user)
                             .where(:id => HelpdeskProjectSetting.where(:handover_enabled => true).select(:project_id))
      HelpdeskMailbox.enabled.includes(:project).where.not(:project_id => project.id)
                     .where(:project_id => participating.select(:id)).to_a
                     .index_by { |mb| mb.mailbox_address.to_s.downcase }
    end

    # Splits a recipient field into what is still mailed and the hand-over
    # mailboxes it named.
    def self.split(value, targets)
      kept = []
      hits = []
      HelpdeskMessage.scan_tokens(value).each do |token|
        next if token.strip.empty?

        mailbox = targets[HelpdeskMessage.bare_address(token).downcase]
        mailbox ? hits << mailbox : kept << token.strip
      end
      [kept.join(', '), hits]
    end

    # +attachments+ are the ones the agent sent with the reply (selected ticket
    # attachments and freshly pasted images).
    def initialize(source:, mailbox:, user:, mode:, note:, attachments: [], contact: nil)
      raise Error, "unknown hand-over mode #{mode.inspect}" unless MODES.include?(mode.to_s)

      @source      = source
      @mailbox     = mailbox
      @user        = user
      @mode        = mode.to_s
      @note        = note.to_s
      @attachments = Array(attachments)
      @contact     = contact
    end

    def call
      project = @mailbox.project
      issue = Issue.new(:project => project, :author => @user)
      issue.tracker     = @mailbox.default_tracker || project.trackers.sorted.first
      issue.subject     = @source.subject.to_s.truncate(255)
      issue.description = description
      issue.priority    = @mailbox.default_priority || IssuePriority.default || issue.priority
      issue.status      = @mailbox.default_status || issue.tracker&.default_status || issue.status
      # The receiving team's queue, as for a ticket that came in by mail
      # (MailProcessor#apply_new_issue_defaults). Mailbox rules are not applied:
      # they match on a sender and a subject this ticket was never mailed with.
      issue.assigned_to = HelpdeskProjectSetting.for_project(project).default_assignee
      # Redmine's own project default as the fallback, as for any new ticket.
      # save(validate: false) skips its before_validation :default_assign, so
      # it is applied here - only when it can actually be assigned.
      fallback = project.default_assigned_to
      issue.assigned_to ||= fallback if fallback && issue.assignable_users.include?(fallback)

      # Silent for now: the caller may still take the hand-over back when its
      # mail fails, and a notification about a deleted ticket cannot be
      # recalled. Handover.notify sends it once the hand-over is final.
      Mailer.with_deliveries(false) do
        Issue.transaction do
          # Without validation like the mail path: a mandatory field of the
          # other project must not swallow the hand-over.
          issue.save(:validate => false) || raise(Error, issue.errors.full_messages.to_sentence)
          relink_attachments(issue, copy_attachments(issue))
          # Inside the transaction: an exception here rolls the ticket back.
          # Committed already, it would be a ticket the caller never got to
          # undo, and the agent's retry would create it twice.
          record_origin(issue)
          link_contact(issue)
          ThreadScope.relate(issue, @source, 'Helpdesk handover')
        end
      end
      Rails.logger.info "Helpdesk handover: ##{@source.id} -> ##{issue.id} " \
                        "(#{project.identifier}, mode #{@mode}, by #{@user.login})"
      issue
    end

    # Redmine's "issue added" notification for a hand-over ticket, sent once
    # the hand-over is final. Respects the target mailbox's "Suppress Redmine
    # notifications" like the mail path. Never raises: the reply is sent by now.
    def self.notify(issue, mailbox)
      return if mailbox&.suppress_notifications?
      return unless Setting.notified_events.include?('issue_added')

      Mailer.deliver_issue_add(issue)
    rescue StandardError => e
      Rails.logger.error "Helpdesk handover: notification for ##{issue&.id} failed: #{e.message}"
    end

    private

    def description
      parts = [I18n.t(:text_helpdesk_handover_header, :issue => "##{@source.id}",
                      :project => @source.project.name, :user => @user.name)]
      parts << @note if @note.strip.present?
      if @mode == 'history'
        parts << I18n.t(:label_helpdesk_handover_history, :issue => "##{@source.id}")
        parts.concat(history_entries)
      end
      parts.join("\n\n")
    end

    # The description first, then every public note, oldest first - quoted, so
    # the other team sees at a glance what was written where.
    def history_entries
      entries = []
      if @source.description.present?
        entries << entry(@source.author, @source.created_on, @source.description)
      end
      @source.journals.where(:private_notes => false).where.not(:notes => [nil, ''])
             .includes(:user).order(:created_on, :id).each do |j|
        entries << entry(j.user, j.created_on, j.notes)
      end
      entries
    end

    def entry(author, at, text)
      who  = author&.name.presence || I18n.t(:label_user_anonymous)
      when_ = at ? I18n.l(at, :format => :short) : ''
      quoted = text.to_s.gsub("\r\n", "\n").split("\n", -1).map { |l| "> #{l}" }.join("\n")
      "#{who}, #{when_}:\n\n#{quoted}"
    end

    # Attachment#copy shares the stored file; Redmine only deletes it from disk
    # once no attachment row points at it any more.
    # Returns { original id => copy }.
    def copy_attachments(issue)
      list = @mode == 'history' ? (@source.attachments.to_a + @attachments) : @attachments
      list.uniq(&:id).each_with_object({}) do |att, map|
        copy = att.copy(:container => issue, :author => @user)
        copy.save!
        map[att.id] = copy if att.id
      end
    end

    # Images in the copied text point at the source ticket's attachments by id
    # (InlineImages.target writes /attachments/download/<id>/...). The other
    # team may not see the source ticket, and the copies outlive it, so the
    # references move to the copies. (?!\d) keeps id 65 out of 653.
    def relink_attachments(issue, copies)
      return if copies.empty? || issue.description.blank?

      text = issue.description.gsub(local_attachment_path) do
        copy = copies[Regexp.last_match(2).to_i]
        copy ? "#{Regexp.last_match(1)}#{copy.id}" : Regexp.last_match(0)
      end
      return if text == issue.description

      # update_all, not update_column: inside the reply request update_column
      # left the row unchanged (the test of the quoted image caught it), while
      # a plain UPDATE does land. update_all also bumps lock_version, so the
      # instance is reloaded to match the row. (Taking the hand-over back would
      # survive a stale one - Redmine's Issue#destroy reloads on
      # StaleObjectError - but nothing else that touches it later does.)
      Issue.where(:id => issue.id).update_all(:description => text)
      issue.reload
    end

    # An attachment path of this Redmine: relative, or under its own host. The
    # lookbehind keeps paths inside other sites' URLs out - a vendor's
    # .../attachments/download/42/manual.pdf is not our attachment 42.
    def local_attachment_path
      own = Regexp.escape("#{Setting.protocol}://#{Setting.host_name}")
      %r{(?<![\w.\-:/])((?:#{own})?/attachments/(?:download/|thumbnail/)?)(\d+)(?!\d)}
    end

    # Where the hand-over arrived, for ThreadScope#opened_here?: a handed-over
    # ticket has no incoming mail that could say so, and moved on to another
    # project it still belongs to the mailbox's replies.
    def record_origin(issue)
      return unless HelpdeskTicketInfo.column_names.include?('handover_mailbox_id')

      info = HelpdeskTicketInfo.find_or_initialize_by(:issue_id => issue.id)
      info.handover_mailbox_id = @mailbox.id
      info.save!
    end

    # The other project gets its own contact for the same customer, so its
    # agents can answer them from their ticket.
    def link_contact(issue)
      return unless @contact&.email.present?

      contact = HelpdeskContact.find_or_create_for(@contact.email, @contact.name, issue.project)
      HelpdeskTicketInfo.link!(issue, contact, @mailbox)
    rescue StandardError => e
      Rails.logger.warn "Helpdesk handover: contact for ##{issue.id} not linked: #{e.message}"
    end
  end
end
