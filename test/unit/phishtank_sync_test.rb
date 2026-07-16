require File.expand_path('../../test_helper', __FILE__)

# Tests fuer den PhishTank-Sync: JSON-Import (Download gestubbt), Duplikate, stale?-Zusammenspiel.
class PhishtankSyncTest < ActiveSupport::TestCase
  SAMPLE_ENTRIES = [
    { 'phish_id' => 1, 'url' => 'https://evil1.example.com/login', 'target' => 'BankA' },
    { 'phish_id' => 2, 'url' => 'https://evil2.example.com/verify', 'target' => 'BankB' },
    # Duplikat von 1 (nach Normalisierung): wird uebersprungen
    { 'phish_id' => 3, 'url' => 'https://EVIL1.example.com/login/', 'target' => 'BankA' }
  ].freeze

  def teardown
    HelpdeskPhishingUrl.delete_all
  end

  def test_run_imports_entries
    sync = stubbed_sync(SAMPLE_ENTRIES)
    count = sync.run

    assert_equal 2, count
    assert_equal 2, HelpdeskPhishingUrl.count
    assert_not_nil HelpdeskPhishingUrl.lookup('https://evil1.example.com/login')
    assert_not_nil HelpdeskPhishingUrl.lookup('https://evil2.example.com/verify')
  end

  def test_run_replaces_existing_mirror
    HelpdeskPhishingUrl.create!(
      :url => 'https://alt.example.com/x', :url_hash => HelpdeskPhishingUrl.hash_for('https://alt.example.com/x'),
      :phish_id => 42, :imported_at => 2.days.ago
    )

    stubbed_sync(SAMPLE_ENTRIES).run

    assert_nil HelpdeskPhishingUrl.lookup('https://alt.example.com/x')
    assert_equal 2, HelpdeskPhishingUrl.count
  end

  def test_run_raises_on_empty_feed
    sync = stubbed_sync([])
    assert_raises(RedmineExpertHelpdesk::PhishtankSync::SyncError) { sync.run }
  end

  def test_run_keeps_old_data_on_failure
    HelpdeskPhishingUrl.create!(
      :url => 'https://alt.example.com/x', :url_hash => HelpdeskPhishingUrl.hash_for('https://alt.example.com/x'),
      :phish_id => 42, :imported_at => 2.days.ago
    )

    sync = RedmineExpertHelpdesk::PhishtankSync.new
    sync.define_singleton_method(:fetch_entries) { raise RedmineExpertHelpdesk::PhishtankSync::SyncError, 'HTTP 500' }

    assert_raises(RedmineExpertHelpdesk::PhishtankSync::SyncError) { sync.run }
    assert_equal 1, HelpdeskPhishingUrl.count
  end

  def test_import_sets_target_and_phish_id
    stubbed_sync(SAMPLE_ENTRIES).run

    entry = HelpdeskPhishingUrl.lookup('https://evil2.example.com/verify')
    assert_equal 2, entry.phish_id
    assert_equal 'BankB', entry.target
  end

  private

  # Sync-Instanz mit gestubbtem Download (kein HTTP im Test)
  def stubbed_sync(entries)
    sync = RedmineExpertHelpdesk::PhishtankSync.new
    sync.define_singleton_method(:fetch_entries) { entries }
    sync
  end
end
