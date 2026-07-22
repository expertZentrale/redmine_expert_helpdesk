require File.expand_path('../../test_helper', __FILE__)

# Tests fuer die Wissensbasis-Helfer auf HelpdeskProjectSetting.
class HelpdeskProjectSettingKbTest < ActiveSupport::TestCase
  def test_ingest_helpers
    ps = HelpdeskProjectSetting.new(:kb_ingest_mode => 'auto')
    assert ps.kb_ingest_auto?
    assert_not ps.kb_ingest_manual?
    ps.kb_ingest_mode = 'manual'
    assert ps.kb_ingest_manual?
    assert_not ps.kb_ingest_auto?
  end

  def test_display_helpers
    ps = HelpdeskProjectSetting.new(:kb_proposal_display => 'both')
    assert ps.kb_show_in_summary?
    assert ps.kb_show_in_sidebar?

    ps.kb_proposal_display = 'summary'
    assert ps.kb_show_in_summary?
    assert_not ps.kb_show_in_sidebar?

    ps.kb_proposal_display = 'sidebar'
    assert_not ps.kb_show_in_summary?
    assert ps.kb_show_in_sidebar?

    ps.kb_proposal_display = 'off'
    assert_not ps.kb_show_in_summary?
    assert_not ps.kb_show_in_sidebar?
  end
end
