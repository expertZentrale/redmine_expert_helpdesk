# Builds "> "-prefixed quotes of a ticket's content so an agent can paste the
# original mail or the conversation so far into a reply to the customer.
#
# Deliberately independent of Redmine::QuoteReply::Builder, which only exists
# from Redmine 7 on while this plugin supports Redmine 5.1 and up. Core's
# builder also has no timestamp in its header, which the conversation modes
# need, so there would be little left to reuse. The quote format itself matches
# core's: a header line, then every line prefixed with "> ", then a blank line.
module RedmineExpertHelpdesk
  class NoteQuoter
    # A very long ticket would otherwise produce a note field nobody can edit.
    MAX_ENTRIES = 50
    MAX_CHARS   = 60_000

    # Rule between entries so a long history stays skimmable while scrolling.
    # A line of dashes is a horizontal rule in CommonMark as well as Textile and
    # still reads as a separator with text formatting switched off. The blank
    # line in front of it is mandatory: directly below a paragraph CommonMark
    # would turn it into a heading instead of a rule.
    SEPARATOR = "---\n\n"

    # content: the text to append. omitted: how many entries were dropped by
    # MAX_ENTRIES/MAX_CHARS, so the UI can say so instead of truncating silently.
    Result = Struct.new(:content, :omitted) do
      def truncated?
        omitted.to_i.positive?
      end
    end

    class << self
      include Redmine::I18n

      # The mail that opened the ticket. MailHandler wrote it into the issue
      # description, and InlineImages has already turned [cid:...] markers into
      # image syntax, so this is what the agent sees on the ticket.
      def description(issue)
        assemble([description_entry(issue)])
      end

      # Description plus journal notes, chronologically.
      # mail_only: keep only notes that correspond to a HelpdeskMessage, i.e.
      # mail actually received from or sent to the customer.
      def conversation(issue, mail_only: false)
        entries = [description_entry(issue)]
        conversation_journals(issue, :mail_only => mail_only).each do |journal|
          entries << quote(header_for(journal.user, journal.created_on), journal.notes)
        end
        assemble(entries)
      end

      private

      # Joins the entries in chronological order and keeps as many as fit;
      # whatever exceeds MAX_ENTRIES or MAX_CHARS is dropped from the end, so
      # truncation removes the newest entries. The description always survives:
      # it is the first entry and MAX_ENTRIES is never zero.
      def assemble(entries)
        entries = entries.reject(&:blank?)
        omitted = [entries.size - MAX_ENTRIES, 0].max
        kept    = entries.first(MAX_ENTRIES)

        content = +''
        kept.each_with_index do |entry, index|
          piece = index.zero? ? entry : SEPARATOR + entry
          if content.length + piece.length > MAX_CHARS && index.positive?
            omitted += kept.size - index
            break
          end
          content << piece
        end
        Result.new(content, omitted)
      end

      def description_entry(issue)
        quote(header_for(issue.author, issue.created_on), issue.description)
      end

      def quote(header, text)
        return '' if text.blank?

        "#{header}\n> #{text.to_s.strip.gsub(/(\r?\n|\r\n?)/, "\n> ")}\n\n"
      end

      def header_for(user, time)
        l(:text_helpdesk_quote_wrote_on,
          :user => (user ? user.name : l(:label_user_anonymous)),
          :date => (time ? format_time(time) : ''))
      end

      # Private notes are excluded unconditionally — deliberately NOT via
      # Journal.visible_notes_condition, which asks "may this user read it".
      # An agent who may read private notes must still not be able to paste one
      # into a mail to the customer, so the only correct filter is the column
      # itself. (visible_notes_condition would also be a no-op here: it is
      # `private_notes = false OR ...`, already satisfied by our WHERE, and it
      # references projects.status, which this un-joined scope does not have.)
      # The private AI summaries of HelpdeskAiSummaryJob drop out here as well.
      def conversation_journals(issue, mail_only:)
        journals = issue.journals
                        .where(:private_notes => false)
                        .where.not(:notes => [nil, ''])
                        .order(:created_on, :id)
                        .includes(:user)
                        .to_a
        linked_ids = HelpdeskMessage.where(:issue_id => issue.id)
                                    .where.not(:journal_id => nil)
                                    .distinct
                                    .pluck(:journal_id)

        return journals.select { |j| linked_ids.include?(j.id) } if mail_only

        # The bookkeeping notes this plugin writes itself (autoresponder sent,
        # phishing links removed) are public and authored by User.anonymous.
        # A real customer mail always carries a HelpdeskMessage, even when
        # MailHandler files it under the anonymous user, so this keeps customer
        # traffic and drops our own notes.
        anonymous_id = User.anonymous.id
        journals.reject { |j| j.user_id == anonymous_id && !linked_ids.include?(j.id) }
      end
    end
  end
end
