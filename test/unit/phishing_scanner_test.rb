require File.expand_path('../../test_helper', __FILE__)

# Tests fuer den Phishing-Scanner: SafeLinks-Dekodierung, URL-Extraktion,
# MIME-Rewrite bei Treffern.
class PhishingScannerTest < ActiveSupport::TestCase
  PHISHING_URL = 'https://evil.example.com/login'.freeze

  def setup
    HelpdeskPhishingUrl.create!(
      :url         => PHISHING_URL,
      :url_hash    => HelpdeskPhishingUrl.hash_for(PHISHING_URL),
      :phish_id    => 99999,
      :target      => 'TestBank',
      :imported_at => Time.current
    )
  end

  def teardown
    HelpdeskPhishingUrl.delete_all
  end

  def test_resolve_safelink_decodes_original_url
    safelink = 'https://eur01.safelinks.protection.outlook.com/?url=' \
               "#{CGI.escape(PHISHING_URL)}&data=05%7C01&sdata=abc&reserved=0"
    scanner = RedmineExpertHelpdesk::PhishingScanner.new
    assert_equal PHISHING_URL, scanner.resolve_safelink(safelink)
  end

  def test_resolve_safelink_leaves_normal_urls_untouched
    scanner = RedmineExpertHelpdesk::PhishingScanner.new
    assert_equal 'https://www.example.com/x', scanner.resolve_safelink('https://www.example.com/x')
  end

  def test_scan_detects_hit_in_plain_text
    mime = plain_mail("Bitte hier anmelden: #{PHISHING_URL} danke!")
    result = RedmineExpertHelpdesk::PhishingScanner.scan(mime)

    assert_equal 1, result[:hits].size
    assert_equal PHISHING_URL, result[:hits].first[:url]
    assert_equal 99999, result[:hits].first[:phish_id]
  end

  def test_scan_rewrites_body_on_hit
    mime = plain_mail("Bitte hier anmelden: #{PHISHING_URL}")
    result = RedmineExpertHelpdesk::PhishingScanner.scan(mime)

    rewritten = Mail.read_from_string(result[:mime])
    body = rewritten.body.decoded.force_encoding('UTF-8')
    assert_not_includes body, PHISHING_URL
    assert_includes body, 'LINK'
    assert_includes body, '99999'
  end

  def test_scan_detects_safelinks_wrapped_hit
    safelink = 'https://eur01.safelinks.protection.outlook.com/?url=' \
               "#{CGI.escape(PHISHING_URL)}&reserved=0"
    mime = plain_mail("Klick: #{safelink}")
    result = RedmineExpertHelpdesk::PhishingScanner.scan(mime)

    assert_equal 1, result[:hits].size
    assert_equal PHISHING_URL, result[:hits].first[:resolved_url]
  end

  def test_scan_clean_mail_returns_unchanged_mime
    mime = plain_mail('Nur harmloser Text mit https://www.example.com/ok Link.')
    result = RedmineExpertHelpdesk::PhishingScanner.scan(mime)

    assert_empty result[:hits]
    assert_equal mime, result[:mime]
  end

  def test_scan_handles_multipart_html
    mime = multipart_mail(
      "Text: #{PHISHING_URL}",
      "<html><body><a href=\"#{PHISHING_URL}\">Login</a></body></html>"
    )
    result = RedmineExpertHelpdesk::PhishingScanner.scan(mime)

    assert_equal 1, result[:hits].size
    rewritten = Mail.read_from_string(result[:mime])
    html = rewritten.html_part.body.decoded.force_encoding('UTF-8')
    text = rewritten.text_part.body.decoded.force_encoding('UTF-8')
    assert_not_includes html, "href=\"#{PHISHING_URL}\""
    assert_not_includes text, PHISHING_URL
  end

  def test_scan_handles_unparseable_mime_gracefully
    result = RedmineExpertHelpdesk::PhishingScanner.scan('kein mime')
    assert_empty result[:hits]
    assert_empty result[:suspicions]
  end

  # --- Verschleierte Links (Verdachtsfaelle) --------------------------------

  def test_redirect_link_is_flagged_as_suspicion
    redirect = 'https://redirect-url.email/?link=https%3A%2F%2Fesarathi.in%2Fsecure%2F'
    result = RedmineExpertHelpdesk::PhishingScanner.scan(plain_mail("Klick: #{redirect}"))

    assert_empty result[:hits]
    assert_equal 1, result[:suspicions].size
    suspicion = result[:suspicions].first
    assert_equal :redirect, suspicion[:reason]
    assert_equal 'https://esarathi.in/secure/', suspicion[:detail]

    body = Mail.read_from_string(result[:mime]).body.decoded.force_encoding('UTF-8')
    assert_includes body, 'esarathi.in/secure'
  end

  def test_redirect_link_with_known_phishing_target_is_full_hit
    redirect = "https://redirect-url.email/?link=#{CGI.escape(PHISHING_URL)}"
    result = RedmineExpertHelpdesk::PhishingScanner.scan(plain_mail("Klick: #{redirect}"))

    assert_equal 1, result[:hits].size
    assert_empty result[:suspicions]
  end

  def test_shortener_link_is_flagged_as_suspicion
    result = RedmineExpertHelpdesk::PhishingScanner.scan(plain_mail('Siehe https://bit.ly/3abcDEF bitte'))

    assert_equal 1, result[:suspicions].size
    assert_equal :shortener, result[:suspicions].first[:reason]
  end

  def test_anchor_mismatch_is_flagged_as_suspicion
    html = '<html><body><a href="https://boese-seite.example.net/login">www.paypal.com</a></body></html>'
    result = RedmineExpertHelpdesk::PhishingScanner.scan(multipart_mail('Text ohne Link', html))

    assert_equal 1, result[:suspicions].size
    suspicion = result[:suspicions].first
    assert_equal :anchor_mismatch, suspicion[:reason]
    assert_includes suspicion[:detail], 'paypal.com'
    assert_includes suspicion[:detail], 'boese-seite.example.net'

    rewritten = Mail.read_from_string(result[:mime]).html_part.body.decoded.force_encoding('UTF-8')
    assert_includes rewritten, '&#9888;'
  end

  def test_matching_anchor_text_is_not_flagged
    html = '<html><body><a href="https://www.example.com/x">www.example.com</a></body></html>'
    result = RedmineExpertHelpdesk::PhishingScanner.scan(multipart_mail('Text', html))

    assert_empty result[:suspicions]
  end

  def test_safelink_is_not_flagged_as_redirect
    safelink = 'https://eur01.safelinks.protection.outlook.com/?url=' \
               "#{CGI.escape('https://harmlos.example.com/doc')}&reserved=0"
    result = RedmineExpertHelpdesk::PhishingScanner.scan(plain_mail("Siehe #{safelink}"))

    assert_empty result[:hits]
    assert_empty result[:suspicions]
  end

  private

  def plain_mail(body)
    Mail.new do
      from    'kunde@example.com'
      to      'helpdesk@example.com'
      subject 'Testmail'
      body    body
    end.to_s
  end

  def multipart_mail(text, html)
    mail = Mail.new do
      from    'kunde@example.com'
      to      'helpdesk@example.com'
      subject 'Testmail'
    end
    mail.text_part = Mail::Part.new { body text }
    mail.html_part = Mail::Part.new do
      content_type 'text/html; charset=UTF-8'
      body html
    end
    mail.to_s
  end
end
