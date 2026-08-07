require File.expand_path('../../test_helper', __FILE__)

# Tests for the global AI/KB feature gates. any_enabled? is what hides the AI statistics tab
# and its controller, so all four on/off combinations are covered.
class AiFeaturesTest < ActiveSupport::TestCase
  def stub_settings(ai, kb)
    Setting.stubs(:plugin_redmine_expert_helpdesk)
           .returns({ 'ai_enabled' => ai, 'kb_enabled' => kb })
  end

  def test_ai_enabled
    stub_settings('1', '0')
    assert RedmineExpertHelpdesk::AiFeatures.ai_enabled?
    assert_not RedmineExpertHelpdesk::AiFeatures.kb_enabled?
  end

  def test_kb_enabled
    stub_settings('0', '1')
    assert_not RedmineExpertHelpdesk::AiFeatures.ai_enabled?
    assert RedmineExpertHelpdesk::AiFeatures.kb_enabled?
  end

  def test_any_enabled_covers_either_feature
    stub_settings('0', '0')
    assert_not RedmineExpertHelpdesk::AiFeatures.any_enabled?

    stub_settings('1', '0')
    assert RedmineExpertHelpdesk::AiFeatures.any_enabled?

    stub_settings('0', '1')
    assert RedmineExpertHelpdesk::AiFeatures.any_enabled?

    stub_settings('1', '1')
    assert RedmineExpertHelpdesk::AiFeatures.any_enabled?
  end

  # Missing keys must read as "off" rather than blow up — a settings hash saved before the
  # feature existed has neither key.
  def test_missing_keys_read_as_disabled
    Setting.stubs(:plugin_redmine_expert_helpdesk).returns({})
    assert_not RedmineExpertHelpdesk::AiFeatures.ai_enabled?
    assert_not RedmineExpertHelpdesk::AiFeatures.kb_enabled?
    assert_not RedmineExpertHelpdesk::AiFeatures.any_enabled?
  end
end
