require File.expand_path('../../test_helper', __FILE__)

# Tests fuer die Projekt-Auswahllogik des Legacy-Imports (reine Normalisierung
# im Konstruktor, keine DB). Der eigentliche Import wird funktional geprueft.
class LegacyContactsImportTest < ActiveSupport::TestCase
  Import = RedmineExpertHelpdesk::LegacyContactsImport

  def test_nil_selects_all
    imp = Import.new(nil)
    assert imp.selected?(5)
    assert imp.selected?(nil)
  end

  def test_subset_selection
    imp = Import.new(['5', '7'])
    assert imp.selected?(5)
    assert imp.selected?(7)
    assert imp.selected?('5')      # String-IDs aus params
    assert_not imp.selected?(6)
    assert_not imp.selected?(nil)  # "kein Projekt" nicht gewaehlt
  end

  def test_no_project_bucket
    imp = Import.new(['none', '5'])
    assert imp.selected?(nil)
    assert imp.selected?(5)
    assert_not imp.selected?(6)
  end

  def test_empty_selection_selects_nothing
    imp = Import.new([])
    assert_not imp.selected?(5)
    assert_not imp.selected?(nil)
  end

  # The plugin settings page reads these counts. Without RedmineUP's tables they
  # must not query them at all: on PostgreSQL a failed statement aborts the
  # surrounding transaction, and every later query of the page fails with it.
  def test_counts_do_not_query_missing_legacy_tables
    conn = ActiveRecord::Base.connection
    skip 'RedmineUP tables present' if conn.table_exists?('helpdesk_tickets') || conn.table_exists?('contacts')

    queried = []
    callback = lambda do |*args|
      payload = args.last
      next if payload[:name] == 'SCHEMA'

      queried << payload[:sql] if payload[:sql] =~ /\b(helpdesk_tickets|contacts)\b/
    end
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      assert_equal 0, Import.misplaced_attachment_count
      assert_equal 0, Import.legacy_contact_count
    end
    assert_empty queried
  end
end
