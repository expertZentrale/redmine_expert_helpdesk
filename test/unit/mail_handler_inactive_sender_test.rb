require File.expand_path('../../test_helper', __FILE__)

# Mail from people whose Redmine account is locked. Core MailHandler drops it
# and logs that at info level only; a helpdesk mailbox that takes mail from
# strangers takes it from them too and files it under their account, as
# RedmineUP's helpdesk did. Every skipped mail is logged at warn with a reason.
class MailHandlerInactiveSenderTest < ActiveSupport::TestCase
  fixtures :all

  # Serves fixed messages and records where they are moved.
  class FakeProvider
    attr_reader :moves

    def initialize(messages)
      @messages = messages # [[MessageMeta, mime], ...]
      @moves = []
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

    def move_message(id, folder)
      @moves << [id, folder]
    end
  end

  def setup
    @issue   = Issue.find(1)
    @project = @issue.project
    @locked  = account('kim.locked@expert.local', User::STATUS_LOCKED)
  end

  def account(mail, status)
    user = User.new(:firstname => 'Kim', :lastname => 'Locked', :mail => mail)
    user.login = mail
    user.random_password
    user.status = status
    user.save!
    user
  end

  def mailbox(unknown_user_mode, attrs = {})
    HelpdeskMailbox.create!({ :project => @project, :mailbox_address => 'support@expert.local',
                              :provider => 'imap', :imap_host => 'mail.example.com',
                              :processed_folder => 'Erledigt', :skipped_folder => 'Uebersprungen',
                              :unknown_user_mode => unknown_user_mode }.merge(attrs))
  end

  def mime(from:, subject:, extra_headers: [])
    lines = ["From: #{from}", 'To: support@expert.local', "Subject: #{subject}",
             "Message-ID: <#{SecureRandom.hex(6)}@expert.local>"]
    lines += extra_headers
    lines += ['MIME-Version: 1.0', 'Content-Type: text/plain; charset=UTF-8', '', 'Ist ok.']
    lines.join("\r\n")
  end

  def run_mail(raw, mailbox)
    parsed = Mail.read_from_string(raw)
    meta = RedmineExpertHelpdesk::MailProvider::MessageMeta.new(
      :id => 'm1', :subject => parsed.subject.to_s, :from_address => parsed.from.first,
      :from_name => '', :received_at => Time.current, :internet_message_id => parsed.message_id
    )
    provider = FakeProvider.new([[meta, raw]])
    result = RedmineExpertHelpdesk::MailProcessor.new(mailbox, provider).process_all
    [result, provider]
  end

  # Warn lines written to Rails.logger while the block runs.
  def warnings
    io = StringIO.new
    original = Rails.logger
    Rails.logger = ActiveSupport::Logger.new(io).tap { |logger| logger.level = ::Logger::WARN }
    yield
    io.string
  ensure
    Rails.logger = original
  end

  # Pins the core behaviour the patch works around, and that the patch only
  # changes it when asked to.
  def test_core_still_drops_mail_from_a_locked_account_without_the_option
    raw = mime(:from => @locked.mail, :subject => 'Hallo')

    assert_equal false, MailHandler.receive(raw, :issue => { :project => @project.identifier },
                                                 :unknown_user => 'accept', :no_permission_check => '1')
  end

  def test_new_ticket_from_a_locked_account_is_filed_under_that_account
    result, provider = run_mail(mime(:from => @locked.mail, :subject => 'Drucker defekt'), mailbox('accept'))

    assert_equal 0, result.skipped
    assert_equal 1, result.created_issues.size
    issue = Issue.find(result.created_issues.first)
    assert_equal @locked, issue.author
    assert_equal [['m1', 'Erledigt']], provider.moves
    assert @locked.reload.locked?, 'receiving the mail must not unlock the account'
  end

  # The case that went missing: an approval answered by mail.
  def test_reply_from_a_locked_account_lands_in_the_ticket
    raw = mime(:from => @locked.mail, :subject => "AW: Berechtigungen [Helpdesk ##{@issue.id}]")
    result, = run_mail(raw, mailbox('accept'))

    assert_equal [@issue.id], result.updated_issues
    journal = @issue.journals.order(:id).last
    assert_equal @locked, journal.user
    assert_includes journal.notes, 'Ist ok.'
  end

  def test_create_mode_files_it_under_the_locked_account_and_creates_no_new_one
    assert_no_difference 'User.count' do
      result, = run_mail(mime(:from => @locked.mail, :subject => 'Hallo'), mailbox('create'))
      assert_equal @locked, Issue.find(result.created_issues.first).author
    end
  end

  def test_an_account_that_was_never_activated_is_accepted_as_well
    registered = account('new.joiner@expert.local', User::STATUS_REGISTERED)
    result, = run_mail(mime(:from => registered.mail, :subject => 'Hallo'), mailbox('accept'))

    assert_equal registered, Issue.find(result.created_issues.first).author
  end

  # A mailbox that turns strangers away keeps core's rule for locked accounts,
  # and now says so where it can be seen.
  def test_mailbox_ignoring_unknown_senders_still_drops_them_and_logs_why
    result = provider = nil
    log = warnings do
      result, provider = run_mail(mime(:from => @locked.mail, :subject => 'Hallo'), mailbox('ignore'))
    end

    assert_equal 1, result.skipped
    assert_empty result.created_issues
    assert_equal [['m1', 'Uebersprungen']], provider.moves
    assert_match(/support@expert\.local\): message skipped \(the sender's Redmine account kim\.locked@expert\.local is not active\)/, log)
  end

  def test_auto_reply_from_a_locked_account_is_still_dropped
    raw = mime(:from => @locked.mail, :subject => 'Abwesend', :extra_headers => ['Auto-Submitted: auto-replied'])
    result = nil
    log = warnings { result, = run_mail(raw, mailbox('accept')) }

    assert_equal 1, result.skipped
    assert_includes log, 'message skipped (auto-generated mail'
  end

  def test_mail_from_an_active_account_is_unchanged
    active = User.find(2)
    result, = run_mail(mime(:from => active.mail, :subject => 'Hallo'), mailbox('accept'))

    assert_equal active, Issue.find(result.created_issues.first).author
  end

  def test_skips_by_mailbox_filters_are_logged_with_their_reason
    log = warnings do
      run_mail(mime(:from => 'spam@example.org', :subject => 'Angebot'),
               mailbox('accept', :deny_list => 'example.org'))
    end

    assert_includes log, 'message skipped (sender not allowed by the allow/deny list) - "Angebot" from spam@example.org'
  end
end
