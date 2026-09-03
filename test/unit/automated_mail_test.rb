require File.expand_path('../../test_helper', __FILE__)

# Header detection and list matching. Both are pure, so a built Mail object and a
# plain string are enough - no DB, no mailbox.
class AutomatedMailTest < ActiveSupport::TestCase
  Detector = RedmineExpertHelpdesk::AutomatedMail

  def mail(headers = {}, body = 'Backup job finished.')
    raw = headers.map { |k, v| "#{k}: #{v}" }.join("\r\n")
    Mail.read_from_string(<<~MIME)
      From: veeam@example.com
      To: helpdesk@example.com
      Subject: Backup job Daily
      #{raw}

      #{body}
    MIME
  end

  # --- header detection -----------------------------------------------------

  def test_plain_mail_is_not_automated
    assert_nil Detector.trigger(mail)
    assert_not Detector.automated?(mail)
  end

  def test_auto_submitted_marks_automated
    assert_match(/auto-submitted/, Detector.trigger(mail('Auto-Submitted' => 'auto-generated')))
    assert Detector.automated?(mail('Auto-Submitted' => 'auto-generated'))
  end

  # RFC 3834: "no" is the explicit statement that a human wrote it.
  def test_auto_submitted_no_is_not_automated
    assert_nil Detector.trigger(mail('Auto-Submitted' => 'no'))
  end

  def test_precedence_bulk_marks_automated
    assert_match(/precedence: bulk/, Detector.trigger(mail('Precedence' => 'bulk')))
  end

  def test_precedence_first_class_is_not_automated
    assert_nil Detector.trigger(mail('Precedence' => 'first-class'))
  end

  def test_auto_response_suppress_marks_automated
    assert_match(/x-auto-response-suppress/, Detector.trigger(mail('X-Auto-Response-Suppress' => 'All')))
  end

  def test_autoresponder_headers_mark_automated
    assert_match(/x-autoreply/, Detector.trigger(mail('X-Autoreply' => 'yes')))
  end

  # --- NDR ------------------------------------------------------------------

  def test_exchange_ndr_is_recognised
    assert Detector.ndr?(mail('X-MS-Exchange-Message-Is-Ndr' => ''))
  end

  def test_plain_mail_is_not_an_ndr
    assert_not Detector.ndr?(mail)
  end

  # --- list matching --------------------------------------------------------

  def test_parse_list_splits_on_newlines_commas_and_semicolons
    assert_equal %w[a@x.de b@y.de c@z.de],
                 Detector.parse_list("A@x.de\n b@y.de ,\r\nc@Z.de;")
  end

  def test_parse_list_of_blank_is_empty
    assert_equal [], Detector.parse_list(nil)
    assert_equal [], Detector.parse_list(" \n ")
  end

  def test_full_address_matches
    assert Detector.list_matches?(%w[veeam@example.com], 'veeam@example.com')
    assert_not Detector.list_matches?(%w[veeam@example.com], 'anna@example.com')
  end

  def test_bare_domain_and_at_domain_match
    assert Detector.list_matches?(%w[example.com], 'veeam@example.com')
    assert Detector.list_matches?(%w[@example.com], 'veeam@example.com')
    assert_not Detector.list_matches?(%w[example.com], 'veeam@other.com')
  end

  def test_matching_ignores_case_and_surrounding_space
    assert Detector.list_matches?(Detector.parse_list('Veeam@Example.COM'), '  veeam@example.com ')
  end

  def test_empty_list_matches_nothing
    assert_not Detector.list_matches?([], 'veeam@example.com')
  end
end
