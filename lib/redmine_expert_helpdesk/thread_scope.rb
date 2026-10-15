# Keeps reply matching inside the project of the mailbox that received a mail.
#
# Redmine's MailHandler treats a mail as a reply as soon as it finds a
# Redmine Message-ID in In-Reply-To/References or a "[... #123]" tag in the
# subject - and appends it to that issue in whatever project it lives in. The
# mailbox only decides the project of *new* tickets. With several projects
# sharing one Redmine, a mail sent to project B's address about a ticket of
# project A therefore landed in A, and together with :no_permission_check any
# sender could write into any ticket of any project, private ones included.
#
# scrub removes every thread marker that points outside the mailbox's project
# before the mail reaches MailHandler, so the mail either continues a ticket of
# this project or becomes a new one here. Markers that point at a ticket of the
# project stay untouched, which keeps the customer's normal reply working.
# Subprojects count as foreign: a mailbox belongs to exactly one project.
#
# The tickets whose markers were removed are returned, so the caller can relate
# the resulting ticket to them.
#
# Opt-in (plugin setting thread_scope_enabled, experimental): it changes which
# ticket an incoming mail lands in, so an existing installation keeps the old
# matching until an admin switches it on.
module RedmineExpertHelpdesk
  class ThreadScope
    Result = Struct.new(:mime, :foreign_issues, :changed)

    def self.enabled?(settings = Setting.plugin_redmine_expert_helpdesk)
      settings['thread_scope_enabled'].to_s == '1'
    end

    def initialize(project)
      @project = project
      @local   = {}
    end

    # Relates two tickets of different projects ("related to"), at most once.
    # No init_journals: Redmine writes a history entry (and a notification) only
    # when the controller asks for it. The relation is meant as a quiet pointer,
    # not as news on a ticket of another team. Redmine's "Allow cross-project
    # issue relations" is enforced by the relation's own validation.
    def self.relate(issue, other, log_prefix = 'Helpdesk')
      return true if IssueRelation.where(:issue_from_id => [issue.id, other.id],
                                         :issue_to_id => [issue.id, other.id]).exists?

      # By id, not by instance: Issue#relation_added writes the relation into
      # whatever journal the passed instance still has open. On the reply path
      # Redmine has closed it by now (test_relation_on_a_reply_adds_no_journal_detail),
      # but fresh instances cannot carry one at all.
      relation = IssueRelation.new(:issue_from_id => issue.id, :issue_to_id => other.id,
                                   :relation_type => IssueRelation::TYPE_RELATES)
      if relation.save
        Rails.logger.info "#{log_prefix}: ##{issue.id} related to ##{other.id} (other project)"
        true
      else
        Rails.logger.info "#{log_prefix}: ##{issue.id} not related to ##{other.id}: " \
                          "#{relation.errors.full_messages.to_sentence}"
        false
      end
    end

    def scrub(mime)
      msg     = Mail.read_from_string(mime)
      foreign = []
      irt     = header_ids(msg, 'in-reply-to')
      refs    = header_ids(msg, 'references')
      # One query for every id in both headers: a long conversation carries
      # dozens of References, and looking each up alone costs a round trip.
      preload_logged(irt + refs)
      @redmine = load_redmine_refs((irt + refs).filter_map { |id| redmine_ref(id) })

      kept_irt  = keep_local_ids(irt, foreign)
      kept_refs = keep_local_ids(refs, foreign)
      subject   = scrub_subject(msg.subject.to_s, foreign)

      changed = kept_irt.size  != irt.size ||
                kept_refs.size != refs.size ||
                subject != msg.subject.to_s
      return Result.new(mime, foreign.uniq, false) unless changed

      msg['in-reply-to'] = nil
      msg['references']  = nil
      msg['in-reply-to'] = kept_irt.map { |id| "<#{id}>" }.join(' ') if kept_irt.any?
      msg['references']  = kept_refs.map { |id| "<#{id}>" }.join(' ') if kept_refs.any?
      msg.subject = subject
      Result.new(msg.to_s, foreign.uniq, true)
    end

    # The issue a Message-ID belongs to: Redmine's own notification ids
    # (redmine.issue-12..., redmine.journal-34...) and every message the
    # helpdesk logged, in and out. Several helpdesk rows can share one id - the
    # same mail went to two projects - so the one of our project wins.
    def issue_for_message_id(id)
      if (ref = redmine_ref(id))
        klass, object_id = ref
        return @redmine ? @redmine[ref] : load_redmine_refs([ref])[ref] if %w[issue journal].include?(klass)

        return nil
      end

      issues = logged_issues(id)
      issues.find { |i| local?(i) } || issues.first
    end

    # A ticket of this project, or one that was opened through a mailbox of
    # this project and moved elsewhere since. The customer keeps answering the
    # address they wrote to; their reply belongs on the moved ticket, not in a
    # new one left behind in the old project.
    def local?(issue)
      return true if issue.project_id == @project.id

      # Cached per scrub: the same ticket is named in several headers.
      @local.fetch(issue.id) { @local[issue.id] = opened_here?(issue) }
    end

    # Whether the mail that created the ticket came in through this project.
    # HelpdeskTicketInfo#helpdesk_mailbox proves nothing: link! fills it on a
    # reply too, so a mail that once reached a foreign ticket through our
    # mailbox (before scoping was switched on) would claim that ticket. The
    # creating mail is the ticket's first incoming message, carries no journal
    # and was stored right after the ticket - the time bound keeps rows from
    # before migration 021, where replies have no journal_id either, out.
    def opened_here?(issue)
      first = HelpdeskMessage.incoming.where(:issue_id => issue.id).order(:id).first
      return false unless first && first.journal_id.nil? && first.helpdesk_mailbox&.project_id == @project.id
      return false unless first.created_at && issue.created_on

      (first.created_at - issue.created_on).abs <= CREATION_WINDOW
    end

    # How long after the ticket the creating mail's row may be stored.
    CREATION_WINDOW = 10.minutes

    private

    # Issues of the logged helpdesk messages named by +ids+, keyed by the bare
    # id; both spellings are queried (see HelpdeskMessage.message_id_variants).
    def preload_logged(ids)
      variants = ids.uniq.flat_map { |id| HelpdeskMessage.message_id_variants(id) }
      @logged = Hash.new { |h, k| h[k] = [] }
      return if variants.empty?

      HelpdeskMessage.where(:message_id => variants).includes(:issue).each do |m|
        @logged[bare_id(m.message_id)] << m.issue if m.issue
      end
    end

    # Preloaded by scrub; a lookup from outside it queries on its own.
    def logged_issues(id)
      return @logged.fetch(bare_id(id), []) if @logged

      HelpdeskMessage.where(:message_id => HelpdeskMessage.message_id_variants(id))
                     .includes(:issue).filter_map(&:issue)
    end

    # ['issue', 12] for Redmine's own notification ids, nil otherwise.
    def redmine_ref(id)
      return nil unless "<#{id}>" =~ MailHandler::MESSAGE_ID_RE

      [Regexp.last_match(1), Regexp.last_match(2).to_i]
    end

    # The issues behind Redmine notification ids, one query per kind instead of
    # one per id. Keyed by the ref; a deleted object maps to nil.
    def load_redmine_refs(refs)
      ids_of   = ->(kind) { refs.select { |k, _| k == kind }.map(&:last).uniq }
      issues   = Issue.where(:id => ids_of.call('issue')).index_by(&:id)
      journals = Journal.where(:id => ids_of.call('journal'), :journalized_type => 'Issue')
                        .includes(:journalized).index_by(&:id)
      refs.uniq.to_h do |kind, oid|
        [[kind, oid], kind == 'issue' ? issues[oid] : journals[oid]&.journalized]
      end
    end

    def bare_id(id)
      id.to_s.strip.delete_prefix('<').delete_suffix('>')
    end

    # Read through the mail gem's parsed accessors, exactly as MailHandler does:
    # they also return an id written without angle brackets, which Redmine's
    # MESSAGE_ID_RE accepts. Scanning for "<...>" would let such an id through.
    def header_ids(msg, name)
      field = msg[name]
      return [] unless field

      parsed = name == 'in-reply-to' ? msg.in_reply_to : msg.references
      Array(parsed).map { |id| id.to_s.strip.delete_prefix('<').delete_suffix('>') }.reject(&:blank?)
    rescue StandardError
      field.value.to_s.scan(/<([^>]+)>|([^\s<>]+@[^\s<>]+)/).flatten.compact
    end

    # Unknown ids are kept: they belong to no ticket, so MailHandler cannot
    # thread on them anyway, and dropping them would only damage the header.
    # A Redmine id that points at a deleted object is foreign - MailHandler
    # would otherwise reject the whole mail as a reply to nothing.
    def keep_local_ids(ids, foreign)
      ids.select do |id|
        issue = issue_for_message_id(id)
        redmine_id = "<#{id}>" =~ MailHandler::MESSAGE_ID_RE
        if issue.nil?
          !redmine_id
        elsif local?(issue)
          true
        else
          foreign << issue
          false
        end
      end
    end

    # Forum reply markers ("[Board - msg123]"). MailHandler posts those into the
    # forum topic, which a helpdesk mailbox never has a reason to do.
    MESSAGE_REPLY_SUBJECT_RE =
      defined?(MailHandler::MESSAGE_REPLY_SUBJECT_RE) ? MailHandler::MESSAGE_REPLY_SUBJECT_RE : /\[[^\]]*msg(\d+)\]/

    # Distinct ticket numbers a subject may name before it is no longer worth
    # looking at. A real reply carries one or two.
    MAX_SUBJECT_TAGS = 20

    # MailHandler's own pattern, so "[Projekt - Ticket #12]" is caught as well
    # as "[#12]". A tag naming a ticket that does not exist is removed for the
    # same reason as above. Repeated until nothing changes: removing an inner
    # tag can expose an outer one ("[#[#4]4]" becomes "[#4]").
    #
    # The subject is the sender's to write, so its tags are looked up in one
    # query per pass, and only MAX_SUBJECT_TAGS distinct numbers in total.
    # Beyond that every tag goes without a lookup: the mail becomes a new
    # ticket, but no marker of another project can survive.
    def scrub_subject(subject, foreign)
      issues = {}
      loop do
        subject = subject.gsub(MESSAGE_REPLY_SUBJECT_RE, '')
        ids     = subject.scan(MailHandler::ISSUE_REPLY_SUBJECT_RE).map { |m| m.first.to_i }.uniq - issues.keys
        return strip_all_tags(subject) if issues.size + ids.size > MAX_SUBJECT_TAGS

        found = Issue.where(:id => ids).index_by(&:id)
        ids.each { |id| issues[id] = found[id] }
        cleaned = subject.gsub(MailHandler::ISSUE_REPLY_SUBJECT_RE) do |tag|
          issue = issues[Regexp.last_match(1).to_i]
          if issue && local?(issue)
            tag
          else
            foreign << issue if issue
            ''
          end
        end
        break subject.gsub(/\s{2,}/, ' ').strip if cleaned == subject

        subject = cleaned
      end
    end

    # Pure string work, no lookups; every pass shortens the subject.
    def strip_all_tags(subject)
      loop do
        cleaned = subject.gsub(MESSAGE_REPLY_SUBJECT_RE, '').gsub(MailHandler::ISSUE_REPLY_SUBJECT_RE, '')
        return cleaned.gsub(/\s{2,}/, ' ').strip if cleaned == subject

        subject = cleaned
      end
    end
  end
end
