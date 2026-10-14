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
    @foreign.project.enable_module!(:helpdesk)
  end

  def teardown
    Setting.cross_project_issue_relations = @with_cross
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

  def test_message_id_variants
    assert_equal ['a@b', '<a@b>'], HelpdeskMessage.message_id_variants('<a@b>')
    assert_equal ['a@b', '<a@b>'], HelpdeskMessage.message_id_variants('a@b')
    assert_empty HelpdeskMessage.message_id_variants(' ')
  end
end
