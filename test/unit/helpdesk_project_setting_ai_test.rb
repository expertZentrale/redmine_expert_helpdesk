require File.expand_path('../../test_helper', __FILE__)

# Tests fuer die KI-Helfer auf HelpdeskProjectSetting: effektiver Prompt
# (erben/erweitern/ersetzen) und der Antworten-Umfang.
class HelpdeskProjectSettingAiTest < ActiveSupport::TestCase
  def setup
    @ps = HelpdeskProjectSetting.new
  end

  def with_global_prompt(text)
    Setting.stubs(:plugin_redmine_expert_helpdesk).returns({ 'ai_prompt' => text })
  end

  def test_effective_prompt_inherit_uses_global
    with_global_prompt('GLOBAL')
    @ps.ai_prompt_mode = 'inherit'
    @ps.ai_prompt = 'PROJECT'
    assert_equal 'GLOBAL', @ps.effective_ai_prompt
  end

  def test_effective_prompt_override_uses_project
    with_global_prompt('GLOBAL')
    @ps.ai_prompt_mode = 'override'
    @ps.ai_prompt = 'PROJECT'
    assert_equal 'PROJECT', @ps.effective_ai_prompt
  end

  def test_effective_prompt_extend_concatenates
    with_global_prompt('GLOBAL')
    @ps.ai_prompt_mode = 'extend'
    @ps.ai_prompt = 'PROJECT'
    assert_equal "GLOBAL\n\nPROJECT", @ps.effective_ai_prompt
  end

  def test_override_falls_back_to_global_when_project_blank
    with_global_prompt('GLOBAL')
    @ps.ai_prompt_mode = 'override'
    @ps.ai_prompt = ''
    assert_equal 'GLOBAL', @ps.effective_ai_prompt
  end

  def test_default_mode_is_inherit
    with_global_prompt('GLOBAL')
    @ps.ai_prompt_mode = nil
    assert_equal 'GLOBAL', @ps.effective_ai_prompt
  end

  def test_scope_for_replies
    @ps.ai_summary_scope = 'initial'
    assert_not @ps.ai_summary_for_replies?
    @ps.ai_summary_scope = 'initial_and_replies'
    assert @ps.ai_summary_for_replies?
  end
end
