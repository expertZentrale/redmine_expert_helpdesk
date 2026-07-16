require File.expand_path('../../test_helper', __FILE__)

# Tests fuer den Phishing.Database-Sync: Plain-Text-Parsing (Download gestubbt),
# Schema-Ergaenzung, Duplikate, Quellen-Trennung.
class PhishingDatabaseSyncTest < ActiveSupport::TestCase
  SAMPLE_BODY = <<~TXT.freeze
    # Kommentar wird uebersprungen
    http://evil1.example.com/login

    https://evil2.example.com/verify
    evil3.example.com/no-scheme
    http://evil1.example.com/login/
  TXT

  def teardown
    HelpdeskPhishingUrl.delete_all
  end

  def test_run_imports_lines
    count = stubbed_sync(SAMPLE_BODY).run

    assert_equal 3, count
    assert_not_nil HelpdeskPhishingUrl.lookup('http://evil1.example.com/login')
    assert_not_nil HelpdeskPhishingUrl.lookup('https://evil2.example.com/verify')
    # Zeile ohne Schema wird als http:// interpretiert
    assert_not_nil HelpdeskPhishingUrl.lookup('http://evil3.example.com/no-scheme')
  end

  def test_run_sets_source
    stubbed_sync(SAMPLE_BODY).run

    entry = HelpdeskPhishingUrl.lookup('http://evil1.example.com/login')
    assert_equal 'phishing_database', entry.source
    assert_nil entry.phish_id
  end

  def test_run_replaces_only_own_source
    HelpdeskPhishingUrl.create!(
      :url => 'https://pt.example.com/x', :url_hash => HelpdeskPhishingUrl.hash_for('https://pt.example.com/x'),
      :phish_id => 42, :source => 'phishtank', :imported_at => 2.days.ago
    )
    HelpdeskPhishingUrl.create!(
      :url => 'https://old-pd.example.com/y', :url_hash => HelpdeskPhishingUrl.hash_for('https://old-pd.example.com/y'),
      :source => 'phishing_database', :imported_at => 2.days.ago
    )

    stubbed_sync(SAMPLE_BODY).run

    # PhishTank-Eintrag bleibt erhalten, alter Phishing.Database-Eintrag ist ersetzt
    assert_not_nil HelpdeskPhishingUrl.lookup('https://pt.example.com/x')
    assert_nil HelpdeskPhishingUrl.lookup('https://old-pd.example.com/y')
  end

  def test_run_raises_on_empty_feed
    sync = stubbed_sync("# nur Kommentare\n\n")
    assert_raises(RedmineExpertHelpdesk::PhishingDatabaseSync::SyncError) { sync.run }
  end

  def test_stale_is_tracked_per_source
    stubbed_sync(SAMPLE_BODY).run

    assert_not HelpdeskPhishingUrl.stale?(6, 'phishing_database')
    assert HelpdeskPhishingUrl.stale?(6, 'phishtank')
  end

  private

  # Sync-Instanz mit gestubbtem Download (kein HTTP im Test)
  def stubbed_sync(body)
    sync = RedmineExpertHelpdesk::PhishingDatabaseSync.new
    sync.define_singleton_method(:fetch_body) { body }
    sync
  end
end
