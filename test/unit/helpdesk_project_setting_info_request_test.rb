require File.expand_path('../../test_helper', __FILE__)

# Tests fuer die Helfer der Vollstaendigkeitspruefung auf HelpdeskProjectSetting:
# Modus-Validierung, Prompt-Kombination und die Textbaustein-Fallbacks.
class HelpdeskProjectSettingInfoRequestTest < ActiveSupport::TestCase
  def setup
    @ps = HelpdeskProjectSetting.new
  end

  def with_settings(hash)
    Setting.stubs(:plugin_redmine_expert_helpdesk).returns(hash)
  end

  def test_mode_validation
    HelpdeskProjectSetting::INFO_REQUEST_MODES.each do |mode|
      @ps.info_request_mode = mode
      @ps.valid?
      assert_empty @ps.errors[:info_request_mode], "#{mode} sollte gueltig sein"
    end

    @ps.info_request_mode = 'bogus'
    @ps.valid?
    assert_not_empty @ps.errors[:info_request_mode]
  end

  def test_enabled_and_ai_mode_predicates
    @ps.info_request_mode = 'off'
    assert_not @ps.info_request_enabled?

    @ps.info_request_mode = 'heuristic'
    assert @ps.info_request_enabled?
    assert_not @ps.info_request_ai_mode?

    @ps.info_request_mode = 'ai'
    assert @ps.info_request_enabled?
    assert @ps.info_request_ai_mode?
  end

  def test_negative_numbers_are_rejected
    @ps.info_request_min_chars = -1
    @ps.valid?
    assert_not_empty @ps.errors[:info_request_min_chars]
  end

  # --- Prompt-Modi (wie effective_ai_prompt, aber eigener globaler Key) ---

  def test_prompt_inherit_uses_global
    with_settings('info_request_ai_prompt' => 'GLOBAL')
    @ps.info_request_ai_prompt_mode = 'inherit'
    @ps.info_request_ai_prompt = 'PROJECT'
    assert_equal 'GLOBAL', @ps.effective_info_request_prompt
  end

  def test_prompt_override_uses_project
    with_settings('info_request_ai_prompt' => 'GLOBAL')
    @ps.info_request_ai_prompt_mode = 'override'
    @ps.info_request_ai_prompt = 'PROJECT'
    assert_equal 'PROJECT', @ps.effective_info_request_prompt
  end

  def test_prompt_extend_concatenates
    with_settings('info_request_ai_prompt' => 'GLOBAL')
    @ps.info_request_ai_prompt_mode = 'extend'
    @ps.info_request_ai_prompt = 'PROJECT'
    assert_equal "GLOBAL\n\nPROJECT", @ps.effective_info_request_prompt
  end

  # Kein Modus gesetzt = erben, damit Bestandsprojekte den zentralen Prompt nutzen.
  def test_prompt_defaults_to_inherit
    with_settings('info_request_ai_prompt' => 'GLOBAL')
    @ps.info_request_ai_prompt = 'PROJECT'
    assert_equal 'GLOBAL', @ps.effective_info_request_prompt
  end

  # Die Refaktorierung auf combine_prompts darf die Zusammenfassung nicht veraendern.
  def test_ai_prompt_still_works_after_refactoring
    with_settings('ai_prompt' => 'GLOBAL')
    @ps.ai_prompt_mode = 'extend'
    @ps.ai_prompt = 'PROJECT'
    assert_equal "GLOBAL\n\nPROJECT", @ps.effective_ai_prompt
  end

  # --- Textbausteine ---

  def test_subject_and_body_fall_back_to_global
    with_settings('info_request_subject' => 'G-SUBJ', 'info_request_body' => 'G-BODY')
    assert_equal 'G-SUBJ', @ps.effective_info_request_subject
    assert_equal 'G-BODY', @ps.effective_info_request_body

    @ps.info_request_subject = 'P-SUBJ'
    @ps.info_request_body    = 'P-BODY'
    assert_equal 'P-SUBJ', @ps.effective_info_request_subject
    assert_equal 'P-BODY', @ps.effective_info_request_body
  end

  def test_keyword_list_delegates_to_check
    @ps.info_request_keywords = "Drucker\n\nSAP , Notebook"
    assert_equal %w[drucker sap notebook], @ps.info_request_keyword_list
  end
end
