require File.expand_path('../../test_helper', __FILE__)

# The From override and its opt-in Reply-To are decided by HelpdeskMailbox
# (see HelpdeskMailboxTest), but every outgoing mail is assembled in a
# different place. These tests pin the wiring: each of the three SMTP send
# sites must actually put #from_address and #reply_to_address on the message.
#
# All three end in mail.deliver!; the test environment's delivery method is
# :test, so the assembled message lands in ActionMailer::Base.deliveries.
class SmtpFromOverrideTest < ActiveSupport::TestCase
  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles,
           :issues, :issue_statuses, :trackers, :enumerations, :enabled_modules

  MAILBOX_ADDRESS = 'helpdesk@example.com'.freeze
  LIST_ADDRESS    = 'liste@example.com'.freeze

  def setup
    ActionMailer::Base.deliveries.clear
    # The three sites log and archive around the actual send; neither is under
    # test here, and both would otherwise need a persisted mailbox or a live
    # provider.
    RedmineExpertHelpdesk::MailLogger.stubs(:track).with(anything).yields
    RedmineExpertHelpdesk::MailProvider.stubs(:for).returns(stub(:archive_sent => nil))
  end

  def teardown
    ActionMailer::Base.deliveries.clear
  end

  # --- Postfach-Varianten -------------------------------------------------

  def mailbox(attrs = {})
    HelpdeskMailbox.new({ :mailbox_address => MAILBOX_ADDRESS,
                          :reply_transport => 'smtp' }.merge(attrs))
  end

  def plain_mailbox
    mailbox
  end

  def overriding_mailbox
    mailbox(:smtp_from_address => LIST_ADDRESS)
  end

  def overriding_mailbox_with_reply_to
    mailbox(:smtp_from_address => LIST_ADDRESS, :smtp_reply_to_mailbox => true)
  end

  # --- 1) Antwort an den Kunden (HelpdeskRepliesController) ---------------

  def send_reply(mbx)
    controller = HelpdeskRepliesController.new
    controller.instance_variable_set(:@issue, Issue.find(1))
    controller.send(:send_reply_smtp, mbx, 'kunde@example.de', nil, nil,
                    'Betreff', '<p>Hallo</p>', [], [], [])
    ActionMailer::Base.deliveries.last
  end

  def test_reply_uses_mailbox_address_without_override
    mail = send_reply(plain_mailbox)
    assert_equal [MAILBOX_ADDRESS], mail.from
    assert_nil mail.reply_to
  end

  def test_reply_uses_override_and_sets_no_reply_to_by_default
    mail = send_reply(overriding_mailbox)
    assert_equal [LIST_ADDRESS], mail.from
    assert_nil mail.reply_to, 'Reply-To must stay unset unless opted in'
  end

  def test_reply_sets_reply_to_when_opted_in
    mail = send_reply(overriding_mailbox_with_reply_to)
    assert_equal [LIST_ADDRESS], mail.from
    assert_equal [MAILBOX_ADDRESS], mail.reply_to
  end

  # --- 2) Erstmail (InitMailer) -------------------------------------------

  def send_initial(mbx)
    mailer = RedmineExpertHelpdesk::InitMailer.new(
      :issue => Issue.find(1), :contact_email => 'kunde@example.de',
      :mailbox => mbx, :user => User.find(2)
    )
    mailer.send(:send_smtp, 'Betreff', '<p>Hallo</p>', '<abc@example.com>')
    ActionMailer::Base.deliveries.last
  end

  def test_initial_mail_uses_mailbox_address_without_override
    mail = send_initial(plain_mailbox)
    assert_equal [MAILBOX_ADDRESS], mail.from
    assert_nil mail.reply_to
  end

  def test_initial_mail_uses_override_and_sets_no_reply_to_by_default
    mail = send_initial(overriding_mailbox)
    assert_equal [LIST_ADDRESS], mail.from
    assert_nil mail.reply_to
  end

  def test_initial_mail_sets_reply_to_when_opted_in
    mail = send_initial(overriding_mailbox_with_reply_to)
    assert_equal [LIST_ADDRESS], mail.from
    assert_equal [MAILBOX_ADDRESS], mail.reply_to
  end

  # --- 3) Autoresponder (MailProcessor) -----------------------------------

  # send_autoresponder also records a HelpdeskMessage and a journal note;
  # neither is under test and both need persisted records.
  def send_autoresponder(mbx)
    HelpdeskMessage.stubs(:create!)
    Journal.stubs(:create!)
    provider = stub(:archive_sent => nil, :send_mail_mime => nil)
    processor = RedmineExpertHelpdesk::MailProcessor.new(mbx, provider)
    contact = stub(:email => 'kunde@example.de', :display_name => 'Kunde')
    processor.send(:send_autoresponder, Issue.find(1), contact, nil)
    ActionMailer::Base.deliveries.last
  end

  def test_autoresponder_uses_mailbox_address_without_override
    mail = send_autoresponder(plain_mailbox)
    assert_equal [MAILBOX_ADDRESS], mail.from
    assert_nil mail.reply_to
  end

  def test_autoresponder_uses_override_and_sets_no_reply_to_by_default
    mail = send_autoresponder(overriding_mailbox)
    assert_equal [LIST_ADDRESS], mail.from
    assert_nil mail.reply_to
  end

  def test_autoresponder_sets_reply_to_when_opted_in
    mail = send_autoresponder(overriding_mailbox_with_reply_to)
    assert_equal [LIST_ADDRESS], mail.from
    assert_equal [MAILBOX_ADDRESS], mail.reply_to
  end

  # --- Weg-Abhaengigkeit --------------------------------------------------

  # Graph and the mailbox's own SMTP server authenticate as the mailbox; the
  # override must not leak into a message built for them. 'graph' never
  # reaches these SMTP paths, so the guard that matters is the model's - this
  # asserts the send site honours it rather than reading the column directly.
  def test_send_sites_ignore_override_on_other_transports
    mbx = mailbox(:reply_transport => 'graph', :smtp_from_address => LIST_ADDRESS,
                  :smtp_reply_to_mailbox => true)
    assert_equal MAILBOX_ADDRESS, mbx.from_address
    assert_nil mbx.reply_to_address

    mail = send_reply(mbx)
    assert_equal [MAILBOX_ADDRESS], mail.from
    assert_nil mail.reply_to
  end
end
