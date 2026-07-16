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
end
