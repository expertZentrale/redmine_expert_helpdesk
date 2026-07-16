require File.expand_path('../../test_helper', __FILE__)

# Tests fuer den lokalen PhishTank-Spiegel: URL-Normalisierung und Lookup.
class HelpdeskPhishingUrlTest < ActiveSupport::TestCase
  def teardown
    HelpdeskPhishingUrl.delete_all
  end

  def test_normalize_lowercases_scheme_and_host
    assert_equal 'https://evil.example.com/Login',
                 HelpdeskPhishingUrl.normalize('HTTPS://EVIL.Example.COM/Login')
  end

  def test_normalize_strips_trailing_slash
    assert_equal 'https://evil.example.com/login',
                 HelpdeskPhishingUrl.normalize('https://evil.example.com/login/')
  end

  def test_normalize_strips_fragment
    assert_equal 'https://evil.example.com/login',
                 HelpdeskPhishingUrl.normalize('https://evil.example.com/login#section')
  end

  def test_normalize_keeps_query_string
    assert_equal 'https://evil.example.com/login?id=1',
                 HelpdeskPhishingUrl.normalize('https://evil.example.com/login?id=1')
  end

  def test_normalize_handles_invalid_url
    assert_equal 'kein url', HelpdeskPhishingUrl.normalize('kein url')
  end

  def test_lookup_finds_url_case_insensitive_host
    create_entry('https://evil.example.com/login')
    assert_not_nil HelpdeskPhishingUrl.lookup('https://EVIL.example.COM/login')
  end

  def test_lookup_finds_url_with_trailing_slash
    create_entry('https://evil.example.com/login')
    assert_not_nil HelpdeskPhishingUrl.lookup('https://evil.example.com/login/')
  end

  def test_lookup_returns_nil_for_unknown_url
    assert_nil HelpdeskPhishingUrl.lookup('https://harmlos.example.com/')
  end

  def test_lookup_returns_nil_for_blank
    assert_nil HelpdeskPhishingUrl.lookup('')
    assert_nil HelpdeskPhishingUrl.lookup(nil)
  end

  def test_stale_when_empty
    assert HelpdeskPhishingUrl.stale?(6)
  end

  def test_stale_when_import_too_old
    create_entry('https://evil.example.com/a', :imported_at => 10.hours.ago)
    assert HelpdeskPhishingUrl.stale?(6)
  end

  def test_not_stale_when_recent
    create_entry('https://evil.example.com/a', :imported_at => 1.hour.ago)
    assert_not HelpdeskPhishingUrl.stale?(6)
  end

  private

  def create_entry(url, attrs = {})
    HelpdeskPhishingUrl.create!({
      :url         => url,
      :url_hash    => HelpdeskPhishingUrl.hash_for(url),
      :phish_id    => 12345,
      :target      => 'TestBank',
      :imported_at => Time.current
    }.merge(attrs))
  end
end
