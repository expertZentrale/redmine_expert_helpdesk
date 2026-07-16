require File.expand_path('../../test_helper', __FILE__)

class MailProcessorFilterTest < ActiveSupport::TestCase
  # Minimal stand-in for GraphClient — no calls are made during filter tests.
  NullGraph = Class.new do
    def method_missing(*); nil; end
    def respond_to_missing?(*); true; end
  end

  AUTO_REPLY_MIME = <<~MIME.freeze
    From: vacations@example.de
    To: helpdesk@expert.de
    Subject: Out of Office
    Auto-Submitted: auto-replied
    MIME-Version: 1.0
    Content-Type: text/plain

    I am out of office.
  MIME

  AUTO_REPLY_WITH_MONITORING_MIME = <<~MIME.freeze
    From: vacations@example.de
    To: helpdesk@expert.de
    Subject: Out of Office
    Auto-Submitted: auto-replied
    X-Monitoring: true
    MIME-Version: 1.0
    Content-Type: text/plain

    I am out of office.
  MIME

  NDR_MIME = <<~MIME.freeze
    From: MAILER-DAEMON@example.de
    To: helpdesk@expert.de
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
    p = processor_for("expert.de\nkunde@partner.de", nil)
    assert_not rejected?(p, 'mitarbeiter@expert.de')
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
end
