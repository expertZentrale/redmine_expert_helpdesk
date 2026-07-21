require File.expand_path('../../test_helper', __FILE__)

# Tests fuer die Gate-Logik des KI-Jobs: ohne globale Aktivierung wird kein
# Client erzeugt und keine Notiz geschrieben.
class HelpdeskAiSummaryJobTest < ActiveSupport::TestCase
  def test_skips_when_globally_disabled
    Setting.stubs(:plugin_redmine_expert_helpdesk).returns({ 'ai_enabled' => '0' })
    # Kein Client, keine Issue-Suche, wenn global aus.
    RedmineExpertHelpdesk::AiClient.expects(:new).never
    Issue.expects(:find_by).never
    assert_nothing_raised { HelpdeskAiSummaryJob.perform_now(999_999) }
  end

  def test_swallows_errors_and_never_raises
    # Global an, aber Issue existiert nicht -> Job endet ruhig (kein Raise).
    Setting.stubs(:plugin_redmine_expert_helpdesk).returns({ 'ai_enabled' => '1' })
    assert_nothing_raised { HelpdeskAiSummaryJob.perform_now(-1) }
  end
end
