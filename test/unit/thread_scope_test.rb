require File.expand_path('../../test_helper', __FILE__)

# A mailbox only ever continues tickets of its own project. Thread markers of
# other projects ([#id] in the subject, Redmine or helpdesk Message-IDs in
# In-Reply-To/References) are removed before MailHandler sees the mail, the mail
# becomes a ticket of the mailbox's project and is related to the other one.
#
# Fixtures: issue 1 lives in project 1 (ecookbook), issue 4 in project 2
# (onlinestore, private).
class ThreadScopeTest < ActiveSupport::TestCase
  fixtures :all

  # Serves fixed messages and records nothing - process_all only needs the
  # interface to exist.
  class FakeProvider
    def initialize(messages)
      @messages = messages # [[MessageMeta, mime], ...]
    end

    def with_session
      yield self
    end

    def list_messages(*)
      @messages.map(&:first)
    end

    def message_mime(id)
      @messages.find { |meta, _| meta.id == id }.last
    end

    def mark_as_read(*); end

    def move_message(*); end
  end

  def setup
    @local   = Issue.find(1) # project 1
    @foreign = Issue.find(4) # project 2
    @project = @local.project
    @mailbox = HelpdeskMailbox.create!(:project => @project, :mailbox_address => 'support-a@expert.local',
                                       :provider => 'imap', :imap_host => 'mail.example.com',
                                       :unknown_user_mode => 'accept')
    @with_cross = Setting.cross_project_issue_relations
    Setting.cross_project_issue_relations = '1'
    @settings_before = Setting.plugin_redmine_expert_helpdesk
    Setting.plugin_redmine_expert_helpdesk = @settings_before.merge('thread_scope_enabled' => '1')
    @foreign.project.enable_module!(:helpdesk)
  end

  def teardown
    Setting.cross_project_issue_relations = @with_cross
    Setting.plugin_redmine_expert_helpdesk = @settings_before
  end

  def mime(subject:, message_id:, in_reply_to: nil, references: nil, from: 'stranger@example.org',
           to: 'support-a@expert.local', cc: nil)
    lines = ["From: #{from}", "To: #{to}"]
    lines << "Cc: #{cc}" if cc
    lines << "Subject: #{subject}"
    lines << "Message-ID: <#{message_id}>"
    lines << "In-Reply-To: #{in_reply_to}" if in_reply_to
    lines << "References: #{references}" if references
    lines += ['MIME-Version: 1.0', 'Content-Type: text/plain; charset=UTF-8', '', 'Hallo, bitte pruefen.']
    lines.join("\r\n")
  end

  def scrub(raw)
    RedmineExpertHelpdesk::ThreadScope.new(@project).scrub(raw)
  end

  # Redmine may store a "relates" relation in either direction.
  def related?(a, b)
    IssueRelation.where(:issue_from_id => [a.id, b.id], :issue_to_id => [a.id, b.id],
                        :relation_type => 'relates').exists?
  end

  def run_mail(raw, message_id, mailbox = @mailbox)
    meta = RedmineExpertHelpdesk::MailProvider::MessageMeta.new(
      :id => message_id, :subject => Mail.read_from_string(raw).subject.to_s,
      :from_address => Mail.read_from_string(raw).from.first, :from_name => '',
      :received_at => Time.current, :internet_message_id => message_id
    )
    RedmineExpertHelpdesk::MailProcessor.new(mailbox, FakeProvider.new([[meta, raw]])).process_all
  end

  # --- ThreadScope -----------------------------------------------------------

  def test_local_subject_tag_is_kept
    result = scrub(mime(:subject => "Re: [##{@local.id}] Drucker", :message_id => 'a@x'))

    assert_not result.changed
    assert_empty result.foreign_issues
  end

  def test_foreign_subject_tag_is_removed_and_reported
    result = scrub(mime(:subject => "[##{@foreign.id}] Bitte an Team A", :message_id => 'a@x'))

    assert result.changed
    assert_equal 'Bitte an Team A', Mail.read_from_string(result.mime).subject
    assert_equal [@foreign], result.foreign_issues
  end

  # MailHandler's pattern also matches the long notification tag.
  def test_foreign_long_subject_tag_is_removed
    result = scrub(mime(:subject => "Re: [OnlineStore - Bug ##{@foreign.id}] Frage", :message_id => 'a@x'))

    assert_equal 'Re: Frage', Mail.read_from_string(result.mime).subject
  end

  # A tag naming no ticket at all would make MailHandler reject the mail as a
  # reply to nothing; removed, it becomes a new ticket instead.
  def test_subject_tag_of_missing_ticket_is_removed
    result = scrub(mime(:subject => '[#987654] Hallo', :message_id => 'a@x'))

    assert_equal 'Hallo', Mail.read_from_string(result.mime).subject
    assert_empty result.foreign_issues
  end

  def test_foreign_redmine_message_id_is_removed_local_one_kept
    foreign_id = "<redmine.issue-#{@foreign.id}.20260101000000@example.net>"
    local_id   = "<redmine.issue-#{@local.id}.20260101000000@example.net>"
    result = scrub(mime(:subject => 'Hallo', :message_id => 'a@x', :references => "#{foreign_id} #{local_id}"))

    refs = Mail.read_from_string(result.mime)['references'].value
    assert_includes refs, "redmine.issue-#{@local.id}."
    assert_not_includes refs, "redmine.issue-#{@foreign.id}."
    assert_equal [@foreign], result.foreign_issues
  end

  def test_foreign_helpdesk_message_id_is_removed
    HelpdeskMessage.create!(:issue => @foreign, :direction => 'out', :message_id => '<reply-1@expert.local>')
    result = scrub(mime(:subject => 'AW: Drucker', :message_id => 'a@x', :in_reply_to => '<reply-1@expert.local>'))

    assert_nil Mail.read_from_string(result.mime)['in-reply-to']
    assert_equal [@foreign], result.foreign_issues
  end

  def test_unknown_message_id_is_kept
    result = scrub(mime(:subject => 'Hallo', :message_id => 'a@x', :in_reply_to => '<somewhere@else.example>'))

    assert_not result.changed
  end

  # --- MailProcessor end to end ----------------------------------------------

  def test_foreign_tag_creates_ticket_in_mailbox_project_and_relates_it
    journals_before = @foreign.journals.count
    result = run_mail(mime(:subject => "[##{@foreign.id}] Bitte an Team A", :message_id => 'case2@x'), 'case2@x')

    assert_equal 1, result.created_issues.size, result.errors.inspect
    created = Issue.find(result.created_issues.first)
    assert_equal @project.id, created.project_id
    assert_equal 'Bitte an Team A', created.subject
    # Neither the mail nor the relation writes into the other project's ticket.
    assert_equal journals_before, @foreign.reload.journals.count
    assert related?(created, @foreign)
  end

  def test_foreign_in_reply_to_alone_creates_ticket_in_mailbox_project
    HelpdeskMessage.create!(:issue => @foreign, :direction => 'in', :message_id => 'orig@customer')
    result = run_mail(mime(:subject => 'AW: Drucker', :message_id => 'case3@x', :in_reply_to => '<orig@customer>'),
                      'case3@x')

    assert_equal 1, result.created_issues.size, result.errors.inspect
    assert_equal @project.id, Issue.find(result.created_issues.first).project_id
  end

  def test_local_tag_still_continues_the_ticket
    result = run_mail(mime(:subject => "Re: [##{@local.id}] Drucker", :message_id => 'local@x',
                           :from => 'jsmith@somenet.foo'), 'local@x')

    assert_equal [@local.id], result.updated_issues, result.errors.inspect
  end

  # Same mail to two mailboxes of one project: one journal, not two.
  def test_same_mail_twice_in_one_project_is_skipped
    second = HelpdeskMailbox.create!(:project => @project, :mailbox_address => 'support-a2@expert.local',
                                     :provider => 'imap', :imap_host => 'mail.example.com')
    raw = mime(:subject => 'Neue Anfrage', :message_id => 'dup@x', :cc => 'support-a2@expert.local')

    first = run_mail(raw, 'dup@x')
    again = run_mail(raw, 'dup@x', second)

    assert_equal 1, first.created_issues.size, first.errors.inspect
    assert_equal 1, again.skipped
    assert_empty again.created_issues + again.updated_issues
  end

  # Same mail to two projects: a ticket in each, related to each other, and each
  # names the other mailbox as co-recipient.
  def test_same_mail_to_two_projects_makes_two_related_tickets
    other = HelpdeskMailbox.create!(:project => @foreign.project, :mailbox_address => 'support-b@expert.local',
                                    :provider => 'imap', :imap_host => 'mail.example.com',
                                    :unknown_user_mode => 'accept')
    raw = mime(:subject => 'An beide Teams', :message_id => 'both@x', :cc => 'support-b@expert.local')

    a = Issue.find(run_mail(raw, 'both@x').created_issues.first)
    b = Issue.find(run_mail(raw, 'both@x', other).created_issues.first)

    assert_equal @project.id, a.project_id
    assert_equal @foreign.project_id, b.project_id
    assert related?(a, b)
    assert_equal [other], HelpdeskMessage.co_recipient_mailboxes(a)
    assert_equal [@mailbox], HelpdeskMessage.co_recipient_mailboxes(b)
  end

  # Redmine's "cross-project relations" switch wins; the ticket is still made.
  def test_no_relation_when_cross_project_relations_are_disabled
    Setting.cross_project_issue_relations = '0'
    result = run_mail(mime(:subject => "[##{@foreign.id}] Hallo", :message_id => 'norel@x'), 'norel@x')

    created = result.created_issues.first
    assert created, result.errors.inspect
    assert_not related?(Issue.find(created), @foreign)
  end

  # A stranger quoting the number of a ticket in a project without the helpdesk
  # gets a ticket here, but no link to that project.
  def test_no_relation_to_ticket_of_project_without_helpdesk
    @foreign.project.disable_module!(:helpdesk)
    journals_before = @foreign.journals.count
    result = run_mail(mime(:subject => "[##{@foreign.id}] Hallo", :message_id => 'nohd@x'), 'nohd@x')

    created = result.created_issues.first
    assert created, result.errors.inspect
    assert_not related?(Issue.find(created), @foreign)
    assert_equal journals_before, @foreign.reload.journals.count
  end

  # The mail gem (and MailHandler) read an id written without angle brackets.
  def test_bracketless_foreign_redmine_id_is_removed
    raw = mime(:subject => 'Hallo', :message_id => 'nb@x',
               :in_reply_to => "redmine.issue-#{@foreign.id}.20260101000000@example.net")
    result = scrub(raw)

    assert_nil Mail.read_from_string(result.mime)['in-reply-to']
    assert_equal [@foreign], result.foreign_issues
  end

  def test_bracketless_foreign_id_creates_ticket_end_to_end
    journals_before = @foreign.journals.count
    raw = mime(:subject => 'Hallo', :message_id => 'nb2@x',
               :in_reply_to => "redmine.issue-#{@foreign.id}.20260101000000@example.net")
    result = run_mail(raw, 'nb2@x')

    assert_equal 1, result.created_issues.size, result.errors.inspect
    assert_equal journals_before, @foreign.reload.journals.count
  end

  # Removing the inner tag exposes the outer one; it must go too.
  def test_nested_foreign_subject_tag_is_removed_completely
    result = scrub(mime(:subject => "[#[##{@foreign.id}]#{@foreign.id}] Frage", :message_id => 'n@x'))

    subject = Mail.read_from_string(result.mime).subject
    assert_no_match MailHandler::ISSUE_REPLY_SUBJECT_RE, subject
  end

  def test_nested_foreign_tag_does_not_write_into_foreign_ticket
    journals_before = @foreign.journals.count
    result = run_mail(mime(:subject => "[#[##{@foreign.id}]#{@foreign.id}] Frage", :message_id => 'n2@x'), 'n2@x')

    assert_equal 1, result.created_issues.size, result.errors.inspect
    assert_equal journals_before, @foreign.reload.journals.count
  end

  # A forum reply marker would make MailHandler post into the forum topic.
  def test_forum_marker_is_removed
    topic = Message.first
    result = scrub(mime(:subject => "Re: [Help - msg#{topic.id}] Frage", :message_id => 'f@x'))

    assert_equal 'Re: Frage', Mail.read_from_string(result.mime).subject
  end

  def test_forum_marker_creates_ticket_instead_of_forum_post
    topic = Message.first
    replies_before = Message.count
    result = run_mail(mime(:subject => "Re: [Help - msg#{topic.id}] Frage", :message_id => 'f2@x'), 'f2@x')

    assert_equal 1, result.created_issues.size, result.errors.inspect
    assert_equal replies_before, Message.count
  end

  # The archived original keeps the headers as received.
  def test_archived_eml_keeps_original_subject
    result = run_mail(mime(:subject => "[##{@foreign.id}] Bitte an Team A", :message_id => 'eml@x'), 'eml@x')

    created = Issue.find(result.created_issues.first)
    eml = created.attachments.detect { |a| a.filename.end_with?('.eml') }
    assert eml, 'no .eml attached'
    assert_equal "[##{@foreign.id}] Bitte an Team A", Mail.read_from_string(File.binread(eml.diskfile)).subject
    assert_equal "[##{@foreign.id}] Bitte an Team A", HelpdeskMessage.find_by(:issue_id => created.id).subject
  end

  # A reply naming only our own agent reply in In-Reply-To continues the
  # ticket. A foreign row with the same id does not pull it elsewhere.
  def test_in_reply_to_of_local_agent_reply_continues_the_ticket
    HelpdeskMessage.create!(:issue => @local, :direction => 'out', :message_id => '<agent-1@expert.local>')
    HelpdeskMessage.create!(:issue => @foreign, :direction => 'in', :message_id => 'agent-1@expert.local')
    result = run_mail(mime(:subject => 'AW: Drucker', :message_id => 'irt-local@x',
                           :in_reply_to => '<agent-1@expert.local>', :from => 'jsmith@somenet.foo'),
                      'irt-local@x')

    assert_equal [@local.id], result.updated_issues, result.errors.inspect
    assert_empty result.created_issues
  end

  # Many references cost one lookup query, not one per id.
  def test_references_are_resolved_in_one_query
    refs = (1..30).map { |i| "<unknown-#{i}@else.example>" }.join(' ')
    raw  = mime(:subject => 'Hallo', :message_id => 'many@x', :references => refs)
    queries = []
    counter = ->(*, payload) { queries << payload[:sql] if payload[:sql].include?('helpdesk_messages') }
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') { scrub(raw) }

    assert_equal 1, queries.size, queries.join("\n")
  end

  # Redmine notification ids are batch-loaded as well: one query for the
  # issues, one for the journals, however many references there are.
  def test_redmine_notification_ids_are_resolved_in_batches
    refs = (1..15).map { |i| "<redmine.journal-#{900_000 + i}.20260101000000@example.net>" } +
           (1..15).map { |i| "<redmine.issue-#{900_000 + i}.20260101000000@example.net>" }
    raw  = mime(:subject => 'Hallo', :message_id => 'many-redmine@x', :references => refs.join(' '))
    queries = []
    counter = ->(*, payload) { queries << payload[:sql] if payload[:sql] =~ /FROM [`"]?(issues|journals)[`"]?/ }
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') { scrub(raw) }

    assert_operator queries.size, :<=, 2, queries.join("\n")
  end

  # A ticket moved away does not list the mailbox it was opened through as
  # "also received by".
  def test_origin_mailbox_of_moved_ticket_is_no_co_recipient
    HelpdeskMessage.create!(:issue => @foreign, :helpdesk_mailbox => @mailbox, :direction => 'in',
                            :message_id => 'moved-co@x', :recipient_to => 'support-a@expert.local')

    assert_empty HelpdeskMessage.co_recipient_mailboxes(@foreign)
  end

  # A reply to our ticket that also names a foreign one: the relation is
  # added quietly, not as a detail of the reply's journal.
  def test_relation_on_a_reply_adds_no_journal_detail
    result = run_mail(mime(:subject => "Re: [##{@local.id}] Drucker", :message_id => 'both@x',
                           :from => 'jsmith@somenet.foo',
                           :references => "<redmine.issue-#{@foreign.id}.20260101000000@example.net>"),
                      'both@x')

    assert_equal [@local.id], result.updated_issues, result.errors.inspect
    assert related?(@local, @foreign)
    journal = @local.reload.journals.order(:id).last
    assert_empty journal.details.where(:property => 'relation')
  end

  # A subject full of ticket numbers costs one lookup per pass, and above the
  # limit none: every tag is removed, the mail becomes a new ticket.
  def test_many_subject_tags_are_removed_without_lookups
    tags    = (1..30).map { |i| "[##{900_000 + i}]" }.join(' ')
    queries = []
    counter = ->(*, payload) { queries << payload[:sql] if payload[:sql] =~ /FROM [`"]?issues[`"]?/ }
    result  = nil
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') do
      result = scrub(mime(:subject => "#{tags} Hallo", :message_id => 'tags@x'))
    end

    assert_equal 'Hallo', Mail.read_from_string(result.mime).subject
    assert_empty queries, queries.first(3).join("\n")
  end

  def test_deeply_nested_subject_tags_are_removed_completely
    nested = ('[#' * 60) + @foreign.id.to_s + (']' * 60)
    result = scrub(mime(:subject => "#{nested} Hallo", :message_id => 'nested-deep@x'))

    assert_no_marker Mail.read_from_string(result.mime).subject.to_s
  end

  def assert_no_marker(subject)
    assert_no_match MailHandler::ISSUE_REPLY_SUBJECT_RE, subject
    assert_no_match RedmineExpertHelpdesk::ThreadScope::MESSAGE_REPLY_SUBJECT_RE, subject
  end

  # One id nested many times: a single lookup, but every pass would expose
  # the next tag. The pass limit stops it; no marker survives, nothing is
  # related or written into the foreign ticket.
  def test_repeated_id_nesting_is_bounded
    # Short enough to stay under MAX_SUBJECT_LENGTH, so the pass limit is
    # what stops it.
    nested = ('[#' * 100) + ("#{@foreign.id}]" * 100)
    assert_operator nested.length, :<, RedmineExpertHelpdesk::ThreadScope::MAX_SUBJECT_LENGTH
    result = nil
    elapsed = Benchmark.realtime { result = scrub(mime(:subject => "#{nested} Hallo", :message_id => 'rep@x')) }

    assert_no_marker Mail.read_from_string(result.mime).subject.to_s
    assert_operator elapsed, :<, 2.0
  end

  # Longer than a header line may be: defanged without looking at it, and
  # without a single issue query.
  def test_overlong_subject_is_defanged
    tags    = (1..200).map { |i| "[##{900_000 + i}]" }.join(' ') + " [##{@foreign.id}] Hallo"
    queries = []
    counter = ->(*, payload) { queries << payload[:sql] if payload[:sql] =~ /FROM [`"]?issues[`"]?/ }
    result  = nil
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') do
      result = scrub(mime(:subject => tags, :message_id => 'long@x'))
    end

    assert_no_marker Mail.read_from_string(result.mime).subject.to_s
    assert_empty result.foreign_issues
    assert_empty queries
  end

  def test_defang_removes_forum_markers_too
    out = RedmineExpertHelpdesk::ThreadScope.new(@project).send(:defang, '[Board - msg45] [#1] Hallo')

    assert_no_marker out
  end

  def test_a_few_subject_tags_are_looked_up_together
    tags    = [@local.id, @foreign.id, 900_001].map { |id| "[##{id}]" }.join(' ')
    queries = []
    counter = ->(*, payload) { queries << payload[:sql] if payload[:sql] =~ /FROM [`"]?issues[`"]? WHERE/ }
    result  = nil
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') do
      result = scrub(mime(:subject => "#{tags} Hallo", :message_id => 'few@x'))
    end

    assert_equal "[##{@local.id}] Hallo", Mail.read_from_string(result.mime).subject
    assert_operator queries.size, :<=, 2, queries.join("\n")
  end

  # Too many header references: both headers go, unchecked, and nothing is
  # related - the sender cannot make us look up or relate hundreds of tickets.
  def test_header_references_over_budget_are_dropped
    ids = (1..60).map do |i|
      HelpdeskMessage.create!(:issue => @foreign, :direction => 'out', :message_id => "<flood-#{i}@expert.local>")
      "<flood-#{i}@expert.local>"
    end
    result = scrub(mime(:subject => 'Hallo', :message_id => 'flood@x', :references => ids.join(' ')))
    out = Mail.read_from_string(result.mime)

    assert result.changed
    assert_nil out['references']
    assert_empty result.foreign_issues
  end

  # Existing foreign tickets in the headers: the moved-ticket check for all of
  # them costs a fixed number of queries.
  def test_moved_ticket_check_is_batched_for_header_references
    foreign = Issue.where.not(:project_id => @project.id).limit(8).to_a
    refs = foreign.each_with_index.map do |issue, i|
      HelpdeskMessage.create!(:issue => issue, :direction => 'in', :message_id => "batch-#{i}@x")
      "<batch-#{i}@x>"
    end
    queries = []
    counter = ->(*, payload) { queries << payload[:sql] if payload[:sql].include?('helpdesk_messages') }
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') do
      scrub(mime(:subject => 'Hallo', :message_id => 'batch@x', :references => refs.join(' ')))
    end

    assert_operator queries.size, :<=, 3, queries.join("\n")
  end

  # The destination project's mailbox fetched the reply to a moved ticket
  # first; the origin mailbox fetching it afterwards adds no second note.
  def test_moved_ticket_reply_fetched_by_destination_first_is_one_note
    opened_through(@foreign, @mailbox)
    dest = HelpdeskMailbox.create!(:project => @foreign.project, :mailbox_address => 'support-b@expert.local',
                                   :provider => 'imap', :imap_host => 'mail.example.com',
                                   :unknown_user_mode => 'accept')
    raw = mime(:subject => "Re: [##{@foreign.id}] Drucker", :message_id => 'dest-first@x',
               :from => 'jsmith@somenet.foo', :cc => 'support-b@expert.local')
    run_mail(raw, 'dest-first@x', dest)
    journals = @foreign.reload.journals.count
    result = run_mail(raw, 'dest-first@x')

    assert_equal 1, result.skipped, result.errors.inspect
    assert_equal journals, @foreign.reload.journals.count
  end

  # --- switch and moved tickets ----------------------------------------------

  # Off (the default for existing installs): a foreign marker still wins, as
  # it always did - the mail is a note on the other project's ticket.
  def test_switched_off_foreign_tag_continues_the_foreign_ticket
    Setting.plugin_redmine_expert_helpdesk = @settings_before.merge('thread_scope_enabled' => '0')
    result = run_mail(mime(:subject => "[##{@foreign.id}] Bitte an Team A", :message_id => 'off@x',
                           :from => 'jsmith@somenet.foo'), 'off@x')

    assert_equal [@foreign.id], result.updated_issues, result.errors.inspect
    assert_empty result.created_issues
  end

  # The row MailProcessor writes for the mail that created a ticket.
  def opened_through(issue, mailbox)
    HelpdeskMessage.create!(:issue => issue, :helpdesk_mailbox => mailbox, :direction => 'in',
                            :message_id => "opened-#{issue.id}@x", :created_at => issue.created_on)
  end

  # A ticket opened through this mailbox and moved to another project since:
  # the customer's reply still belongs on it.
  def test_ticket_moved_away_keeps_receiving_replies
    opened_through(@foreign, @mailbox)

    assert_not scrub(mime(:subject => "Re: [##{@foreign.id}] Drucker", :message_id => 'a@x')).changed
    result = run_mail(mime(:subject => "Re: [##{@foreign.id}] Drucker", :message_id => 'moved@x',
                           :from => 'jsmith@somenet.foo'), 'moved@x')
    assert_equal [@foreign.id], result.updated_issues, result.errors.inspect
  end

  # Scoping off, a mail through our mailbox reached a foreign ticket and
  # link! recorded our mailbox on it. Switched on, that ticket is still foreign.
  def test_reply_recorded_before_switching_on_does_not_claim_the_ticket
    Setting.plugin_redmine_expert_helpdesk = @settings_before.merge('thread_scope_enabled' => '0')
    run_mail(mime(:subject => "[##{@foreign.id}] Vorher", :message_id => 'before@x',
                  :from => 'jsmith@somenet.foo'), 'before@x')
    assert_equal @mailbox, HelpdeskTicketInfo.find_by(:issue_id => @foreign.id)&.helpdesk_mailbox

    Setting.plugin_redmine_expert_helpdesk = @settings_before.merge('thread_scope_enabled' => '1')
    result = scrub(mime(:subject => "[##{@foreign.id}] Nachher", :message_id => 'after@x'))
    assert result.changed
    assert_equal [@foreign], result.foreign_issues
  end

  # A reply to a moved ticket reaching two mailboxes of the old project: one
  # note, not two - the duplicate check also knows the receiving mailbox.
  def test_moved_ticket_reply_to_two_mailboxes_is_one_note
    opened_through(@foreign, @mailbox)
    second = HelpdeskMailbox.create!(:project => @project, :mailbox_address => 'support-a3@expert.local',
                                     :provider => 'imap', :imap_host => 'mail.example.com',
                                     :unknown_user_mode => 'accept')
    raw = mime(:subject => "Re: [##{@foreign.id}] Drucker", :message_id => 'twice-moved@x',
               :from => 'jsmith@somenet.foo', :cc => 'support-a3@expert.local')
    run_mail(raw, 'twice-moved@x')
    journals = @foreign.reload.journals.count
    result = run_mail(raw, 'twice-moved@x', second)

    assert_equal 1, result.skipped, result.errors.inspect
    assert_equal journals, @foreign.reload.journals.count
  end

  def test_message_id_variants
    assert_equal ['a@b', '<a@b>'], HelpdeskMessage.message_id_variants('<a@b>')
    assert_equal ['a@b', '<a@b>'], HelpdeskMessage.message_id_variants('a@b')
    assert_empty HelpdeskMessage.message_id_variants(' ')
  end
end
