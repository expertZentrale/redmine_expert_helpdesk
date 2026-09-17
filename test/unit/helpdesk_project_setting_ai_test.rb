require File.expand_path('../../test_helper', __FILE__)

# Tests fuer die KI-Helfer auf HelpdeskProjectSetting: effektiver Prompt
# (erben/erweitern/ersetzen) und der Antworten-Umfang.
class HelpdeskProjectSettingAiTest < ActiveSupport::TestCase

  # Plugin settings live in one global hash that survives the transaction
  # rollback between tests, so a test that writes one leaks into whatever runs
  # next. Snapshot and restore instead of merging a key back: CI caught exactly
  # this as a seed-dependent failure of the "falls back to the default" test.
  def setup_plugin_settings_snapshot
    @plugin_settings_snapshot = Setting.plugin_redmine_expert_helpdesk.dup
  end

  def restore_plugin_settings_snapshot
    Setting.plugin_redmine_expert_helpdesk = @plugin_settings_snapshot if @plugin_settings_snapshot
  end

  def teardown
    restore_plugin_settings_snapshot
  end
  def setup
    setup_plugin_settings_snapshot
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

  # --- Antwortvorschlag (teilt sich die Prompt-Modi mit der Zusammenfassung) ---

  def test_effective_ai_answer_prompt_inherits_extends_and_overrides
    Setting.plugin_redmine_expert_helpdesk =
      Setting.plugin_redmine_expert_helpdesk.merge('ai_answer_prompt' => 'ZENTRAL')
    ps = HelpdeskProjectSetting.new(:project_id => 1, :ai_answer_prompt => 'PROJEKT')

    ps.ai_answer_prompt_mode = 'inherit'
    assert_equal 'ZENTRAL', ps.effective_ai_answer_prompt

    ps.ai_answer_prompt_mode = 'extend'
    assert_equal "ZENTRAL\n\nPROJEKT", ps.effective_ai_answer_prompt

    ps.ai_answer_prompt_mode = 'override'
    assert_equal 'PROJEKT', ps.effective_ai_answer_prompt
  end

  def test_invalid_ai_answer_prompt_mode_is_rejected
    ps = HelpdeskProjectSetting.new(:project_id => 1, :ai_answer_prompt_mode => 'nonsense')
    assert_not ps.valid?
    assert ps.errors[:ai_answer_prompt_mode].present?
  end

  def test_parse_ai_answer_min_score_accepts_comma_and_rejects_garbage
    assert_in_delta 0.85, HelpdeskProjectSetting.parse_ai_answer_min_score('0,85'), 0.0001
    assert_raises(ArgumentError) { HelpdeskProjectSetting.parse_ai_answer_min_score('o,7') }
  end

  def test_effective_ai_answer_min_score_falls_back_to_default_on_invalid_global_value
    Setting.plugin_redmine_expert_helpdesk =
      Setting.plugin_redmine_expert_helpdesk.merge('ai_answer_min_score' => 'o,7')
    ps = HelpdeskProjectSetting.new(:project_id => 1, :ai_answer_min_score => nil)
    assert_equal RedmineExpertHelpdesk::AnswerDrafter::DRAFT_MIN_SCORE, ps.effective_ai_answer_min_score
  end
end
