require File.expand_path('../../test_helper', __FILE__)

class MailProcessorFilterTest < ActiveSupport::TestCase
  # Minimal stand-in for the mail provider — no calls are made during filter tests.
  NullGraph = Class.new do
    def method_missing(*); nil; end
    def respond_to_missing?(*); true; end
  end

  # Records the provider calls MailProcessor makes when moving messages.
  FakeProvider = Class.new do
    attr_reader :calls

    def initialize
      @calls = []
    end

    def with_session
      @calls << [:with_session]
      yield self
    end

    def mark_as_read(id)
      @calls << [:mark_as_read, id]
    end

    def move_message(id, folder)
      @calls << [:move_message, id, folder]
    end

    def send_mail_mime(mime)
      @calls << [:send_mail_mime, mime]
    end

    def archive_sent(mime)
      @calls << [:archive_sent, mime]
    end
  end

  AUTO_REPLY_MIME = <<~MIME.freeze
    From: vacations@example.de
    To: helpdesk@example.com
    Subject: Out of Office
    Auto-Submitted: auto-replied
    MIME-Version: 1.0
    Content-Type: text/plain

    I am out of office.
  MIME

  AUTO_REPLY_WITH_MONITORING_MIME = <<~MIME.freeze
    From: vacations@example.de
    To: helpdesk@example.com
    Subject: Out of Office
    Auto-Submitted: auto-replied
    X-Monitoring: true
    MIME-Version: 1.0
    Content-Type: text/plain

    I am out of office.
  MIME

  NDR_MIME = <<~MIME.freeze
    From: MAILER-DAEMON@example.de
    To: helpdesk@example.com
    Subject: Undelivered Mail Returned to Sender
    Content-Type: multipart/report; report-type=delivery-status; boundary="NDR"
    MIME-Version: 1.0

    --NDR
    Content-Type: text/plain

    Delivery failed.

    --NDR--
  MIME

  def processor_for(allow, deny, extra_attrs = {})
    mailbox = HelpdeskMailbox.new(
      { :allow_list => allow, :deny_list => deny }.merge(extra_attrs)
    )
    RedmineExpertHelpdesk::MailProcessor.new(mailbox, NullGraph.new)
  end

  def rejected?(processor, sender)
    processor.send(:sender_rejected?, sender)
  end

  # --- Black-/Whitelist ---------------------------------------------------

  def test_no_lists_allows_everything
    p = processor_for(nil, nil)
    assert_not rejected?(p, 'wer@auch-immer.de')
  end

  def test_deny_list_by_address_and_domain
    p = processor_for(nil, "spam@boese.de\nschlecht.de")
    assert rejected?(p, 'spam@boese.de')
    assert rejected?(p, 'jemand@schlecht.de')
    assert_not rejected?(p, 'gut@example.de')
  end

  def test_allow_list_restricts_to_entries
    p = processor_for("example.com\nkunde@partner.de", nil)
    assert_not rejected?(p, 'mitarbeiter@example.com')
    assert_not rejected?(p, 'kunde@partner.de')
    assert rejected?(p, 'fremd@anders.de')
  end

  def test_domain_entries_with_at_prefix
    p = processor_for(nil, '@boese.de')
    assert rejected?(p, 'x@boese.de')
  end

  # --- Auto-Reply-Filter --------------------------------------------------

  def test_auto_reply_filter_disabled_by_default
    p = processor_for(nil, nil)
    assert_not p.send(:auto_reply_filtered?, AUTO_REPLY_MIME, 'vacations@example.de')
  end

  def test_auto_reply_is_filtered
    p = processor_for(nil, nil, :auto_reply_filter_enabled => true)
    assert p.send(:auto_reply_filtered?, AUTO_REPLY_MIME, 'vacations@example.de')
  end

  def test_ndr_is_not_filtered_despite_auto_reply_header
    p = processor_for(nil, nil, :auto_reply_filter_enabled => true)
    assert_not p.send(:auto_reply_filtered?, NDR_MIME, 'mailer-daemon@example.de')
  end

  def test_sender_whitelist_bypasses_auto_reply_filter
    p = processor_for(nil, nil,
                      :auto_reply_filter_enabled   => true,
                      :auto_reply_sender_whitelist => 'vacations@example.de')
    assert_not p.send(:auto_reply_filtered?, AUTO_REPLY_MIME, 'vacations@example.de')
  end

  def test_header_whitelist_bypasses_auto_reply_filter
    p = processor_for(nil, nil,
                      :auto_reply_filter_enabled   => true,
                      :auto_reply_header_whitelist => 'X-Monitoring: true')
    assert_not p.send(:auto_reply_filtered?, AUTO_REPLY_WITH_MONITORING_MIME, 'vacations@example.de')
  end

  # --- Provider-Delegation --------------------------------------------------

  def test_moves_are_delegated_to_the_provider
    provider = FakeProvider.new
    mailbox = HelpdeskMailbox.new(:processed_folder => 'Verarbeitet',
                                  :skipped_folder   => 'Uebersprungen',
                                  :failed_folder    => 'Fehler')
    processor = RedmineExpertHelpdesk::MailProcessor.new(mailbox, provider)

    processor.send(:move_processed, '1')
    processor.send(:move_skipped, '2')
    processor.send(:move_failed, '3')

    assert_includes provider.calls, [:move_message, '1', 'Verarbeitet']
    assert_includes provider.calls, [:move_message, '2', 'Uebersprungen']
    assert_includes provider.calls, [:move_message, '3', 'Fehler']
    assert_equal 3, provider.calls.count { |c| c.first == :mark_as_read }
  end

  # A fetch cycle opens exactly one provider session, so IMAP does not
  # reconnect per message.
  def test_process_all_opens_one_session
    provider = FakeProvider.new
    def provider.list_messages(*); raise 'stop here'; end
    mailbox = HelpdeskMailbox.new(:mailbox_address => 'hd@example.com')
    def mailbox.update_columns(*); true; end

    RedmineExpertHelpdesk::MailProcessor.new(mailbox, provider).process_all(5)
    assert_equal 1, provider.calls.count { |c| c.first == :with_session }
  end

  # --- Autoresponder transport ----------------------------------------------
  # The autoresponder follows the mailbox's reply transport like every other
  # outgoing mail; sending it through the fetch backend regardless was a bug.

  def test_autoresponder_uses_the_mailbox_own_smtp_for_the_provider_transport
    provider = FakeProvider.new
    mailbox = HelpdeskMailbox.new(:provider => 'imap', :reply_transport => 'provider')
    processor = RedmineExpertHelpdesk::MailProcessor.new(mailbox, provider)

    assert_same provider, processor.send(:autoresponder_provider)
  end

  # 'graph' means the central registration even when the mail arrived over IMAP,
  # so the fetch provider must not be reused. Only legal for a Microsoft-hosted
  # mailbox, which is the configuration this asserts.
  def test_autoresponder_uses_graph_when_the_transport_says_so
    provider = FakeProvider.new
    mailbox = HelpdeskMailbox.new(:provider => 'imap', :oauth_preset => 'microsoft',
                                  :reply_transport => 'graph')
    processor = RedmineExpertHelpdesk::MailProcessor.new(mailbox, provider)

    assert_kind_of RedmineExpertHelpdesk::GraphProvider, processor.send(:autoresponder_provider)
  end

  def test_autoresponder_goes_through_redmine_smtp_and_never_touches_the_provider
    provider = FakeProvider.new
    mailbox = HelpdeskMailbox.new(:reply_transport => 'smtp')
    processor = RedmineExpertHelpdesk::MailProcessor.new(mailbox, provider)

    mail = Mail.new(:from => 'hd@example.com', :to => 'kunde@example.com', :subject => 'Hi')
    mail.delivery_method(:test)
    delivered = []
    mail.define_singleton_method(:deliver!) { delivered << self }
    mail.define_singleton_method(:delivery_method) { |*_args| nil }

    processor.send(:deliver_autoresponder, mail)

    assert_equal 1, delivered.size
    assert provider.calls.none? { |c| c.first == :send_mail_mime }
    # Redmine's relay files nothing in the mailbox, so we archive it ourselves.
    assert provider.calls.any? { |c| c.first == :archive_sent }
  end
end
