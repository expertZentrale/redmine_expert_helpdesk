require File.expand_path('../../test_helper', __FILE__)

# Detail levels of the knowledge-base extraction: built-in prompt per level,
# recognising the seeded old default as "not customised", and how the project
# combines level and prompt with the central settings.
class KnowledgeExtractDetailTest < ActiveSupport::TestCase
  fixtures :projects

  Extractor = RedmineExpertHelpdesk::KnowledgeExtractor

  def setup
    @plugin_settings_snapshot = Setting.plugin_redmine_expert_helpdesk.dup
    @ps = HelpdeskProjectSetting.new(:project_id => 1)
  end

  def teardown
    Setting.plugin_redmine_expert_helpdesk = @plugin_settings_snapshot if @plugin_settings_snapshot
  end

  # --- built-in prompts ----------------------------------------------------

  def test_every_level_builds_a_json_prompt
    Extractor::DETAIL_LEVELS.each do |level|
      prompt = Extractor.prompt_for(level)
      assert_includes prompt, '"problem"', level
      assert_includes prompt, '"has_solution"', level
      assert_includes prompt, 'Betreff:', level
    end
  end

  def test_general_is_the_previous_default_prompt
    assert_equal Extractor::DEFAULT_PROMPT, Extractor.prompt_for('general')
    assert_includes Extractor::DEFAULT_PROMPT, 'verallgemeinert'
  end

  def test_finer_levels_keep_details_but_never_secrets
    specific = Extractor.prompt_for('specific')
    most     = Extractor.prompt_for('most_specific')
    assert_includes specific, 'Fehlercode'
    assert_includes most, 'Pfade'
    assert_includes most, 'Verallgemeinere'
    [specific, most].each { |p| assert_includes p, 'Passwoerter' }
  end

  # The docs promise no credentials/personal data at any level - general too.
  def test_privacy_rule_is_sent_at_every_level
    Extractor::DETAIL_LEVELS.each { |l| assert_includes Extractor.prompt_for(l), 'personenbezogenen Daten', l }
  end

  # Own prompts (central or project override) keep the privacy instruction -
  # appended once, not again when the text already carries it.
  def test_own_prompts_keep_the_privacy_rule
    own = Extractor.with_privacy('Eigener Prompt')
    assert own.start_with?('Eigener Prompt')
    assert_includes own, 'personenbezogenen Daten'
    assert_equal own, Extractor.with_privacy(own)
    assert_equal Extractor.prompt_for('specific'), Extractor.with_privacy(Extractor.prompt_for('specific'))

    @ps.kb_extract_prompt = 'Nur JSON bitte.'
    @ps.kb_extract_prompt_mode = 'override'
    assert_includes @ps.effective_kb_extract_prompt({}), 'personenbezogenen Daten'
  end

  # The 0.20.3 default (no privacy sentence) sits in existing installs' settings.
  def test_previous_default_without_privacy_rule_is_not_custom
    previous = Extractor::LEGACY_DEFAULT_PROMPTS.last
    assert_includes previous, 'Betreff:'
    assert_not_includes previous, 'Passwoerter'
    assert_not Extractor.custom_prompt?(previous)
  end

  def test_unknown_level_falls_back_to_general
    assert_equal Extractor.prompt_for('general'), Extractor.prompt_for('bogus')
    assert_equal Extractor.prompt_for('general'), Extractor.prompt_for(nil)
  end

  # --- central settings ------------------------------------------------------

  def test_seeded_default_and_builtins_are_not_custom
    assert_not Extractor.custom_prompt?(nil)
    assert_not Extractor.custom_prompt?('  ')
    Extractor::DETAIL_LEVELS.each { |l| assert_not Extractor.custom_prompt?(Extractor.prompt_for(l)), l }
    # Stored via a textarea: line endings and trailing blanks may differ.
    assert_not Extractor.custom_prompt?(Extractor::DEFAULT_PROMPT.gsub("\n", "\r\n") + "  ")
    assert Extractor.custom_prompt?('Eigener Prompt')
  end

  # Installs from before 0.7.1 carry the default without the subject sentence -
  # found exactly so in a real settings row (with \r\n from the textarea).
  def test_formerly_shipped_default_is_not_custom
    legacy = Extractor::LEGACY_DEFAULT_PROMPTS.first
    assert_not_includes legacy, 'Betreff'
    assert_not Extractor.custom_prompt?(legacy.gsub("\n", "\r\n"))
    assert_equal Extractor.prompt_for('specific'), Extractor.central_prompt({ 'kb_extract_prompt' => legacy }, 'specific')
  end

  # Existing installs carry the old default in kb_extract_prompt (init.rb seeded
  # it) - it must not pin them to 'general'.
  def test_central_prompt_ignores_the_seeded_default
    settings = { 'kb_extract_prompt' => Extractor::DEFAULT_PROMPT }
    assert_equal Extractor.prompt_for('most_specific'), Extractor.central_prompt(settings, 'most_specific')
    assert_equal Extractor.with_privacy('EIGEN'),
                 Extractor.central_prompt({ 'kb_extract_prompt' => 'EIGEN' }, 'most_specific')
  end

  def test_central_detail_falls_back_when_unset_or_invalid
    assert_equal 'general', Extractor.central_detail({})
    assert_equal 'general', Extractor.central_detail(nil)
    assert_equal 'general', Extractor.central_detail('kb_extract_detail' => 'bogus')
    assert_equal 'specific', Extractor.central_detail('kb_extract_detail' => 'specific')
  end

  # --- project combination ---------------------------------------------------

  def test_project_level_beats_central_level
    settings = { 'kb_extract_detail' => 'specific' }
    assert_equal 'specific', @ps.effective_kb_extract_detail(settings)
    @ps.kb_extract_detail = 'most_specific'
    assert_equal 'most_specific', @ps.effective_kb_extract_detail(settings)
  end

  def test_inherit_uses_builtin_prompt_of_the_project_level
    @ps.kb_extract_detail = 'most_specific'
    @ps.kb_extract_prompt = 'PROJEKT'
    @ps.kb_extract_prompt_mode = 'inherit'
    assert_equal Extractor.prompt_for('most_specific'), @ps.effective_kb_extract_prompt({})
  end

  def test_extend_appends_project_text
    @ps.kb_extract_detail = 'specific'
    @ps.kb_extract_prompt = 'Nenne immer die Filiale.'
    @ps.kb_extract_prompt_mode = 'extend'
    prompt = @ps.effective_kb_extract_prompt({})
    assert prompt.start_with?(Extractor.prompt_for('specific').strip), prompt
    assert prompt.end_with?('Nenne immer die Filiale.')
  end

  def test_override_uses_project_text_and_central_custom_prompt_otherwise
    @ps.kb_extract_prompt = 'PROJEKT'
    @ps.kb_extract_prompt_mode = 'override'
    assert_equal Extractor.with_privacy('PROJEKT'), @ps.effective_kb_extract_prompt('kb_extract_prompt' => 'ZENTRAL')
    @ps.kb_extract_prompt_mode = 'inherit'
    assert_equal Extractor.with_privacy('ZENTRAL'), @ps.effective_kb_extract_prompt('kb_extract_prompt' => 'ZENTRAL')
  end

  def test_validates_level_and_mode
    @ps.kb_extract_detail = 'bogus'
    assert_not @ps.valid?
    assert @ps.errors[:kb_extract_detail].any?
    @ps.kb_extract_detail = ''
    @ps.kb_extract_prompt_mode = 'bogus'
    assert_not @ps.valid?
    assert @ps.errors[:kb_extract_prompt_mode].any?
    assert @ps.errors[:kb_extract_detail].empty?
  end

  # --- JSON with paths -----------------------------------------------------------

  # Real model answer (most_specific, UNC path): "\W" and "\C" are no JSON
  # escapes, json >= 2.10 rejects them and the entry used to be dropped silently.
  def test_parse_repairs_unescaped_windows_paths
    raw = '{"problem":"DBX00101","solution":"2. In \\\\SRV-DATEV01\\WINDVSW1\\CONFIGDB die Datei ' \
          'dbserver.ini pruefen.","has_solution":true}'
    data = Extractor.new({}).send(:parse_json, raw)
    assert_not_nil data
    assert_includes data['solution'], 'WINDVSW1\\CONFIGDB'
    assert_equal true, data['has_solution']
  end

  # Valid JSON with the wrong meaning: \n, \t, \b, \f inside a verbatim path
  # parse without error into control characters.
  def test_parse_repairs_paths_whose_backslashes_look_like_escapes
    parse = ->(raw) { Extractor.new({}).send(:parse_json, raw)['solution'] }
    assert_equal 'C:\\new\\test', parse.call('{"solution":"C:\\new\\test"}')
    assert_equal 'Datei C:\\boot\\file loeschen', parse.call('{"solution":"Datei C:\\boot\\file loeschen"}')
    # Whole UNC path kept, leading double backslash included.
    assert_equal 'In \\\\SRV01\\WINDVSW1\\CONFIGDB', parse.call('{"solution":"In \\\\SRV01\\WINDVSW1\\CONFIGDB"}')
  end

  # UNC spellings seen from the model: unescaped with escape-like segments, and
  # the most common one - separators escaped, only the prefix short.
  def test_parse_repairs_unc_spellings
    parse = ->(raw) { Extractor.new({}).send(:parse_json, raw)['solution'] }
    # Unescaped, every segment escape-like (\n, \t): JSON alone would accept it.
    assert_equal '\\\\server\\new\\test', parse.call('{"solution":"\\\\server\\new\\test"}')
    # Separators escaped, only the prefix short - the model's usual spelling.
    assert_equal 'In \\\\SRV01\\WINDVSW1\\CONFIGDB', parse.call('{"solution":"In \\\\SRV01\\\\WINDVSW1\\\\CONFIGDB"}')
    # Fully escaped stays as it is.
    assert_equal 'In \\\\SRV01\\Share', parse.call('{"solution":"In \\\\\\\\SRV01\\\\Share"}')
  end

  # Spellings mixed within one path: each separator is repaired on its own.
  def test_parse_repairs_mixed_separators
    parse = ->(raw) { Extractor.new({}).send(:parse_json, raw)['solution'] }
    assert_equal '\\\\SRV01\\Share\\new\\test', parse.call('{"solution":"\\\\SRV01\\\\Share\\new\\test"}')
    assert_equal 'C:\\Program\\new', parse.call('{"solution":"C:\\\\Program\\new"}')
    # Escapes that belong in a path survive: umlaut as \u, quote after the path.
    assert_equal "C:\\Benutzer\\M\u00fcller", parse.call('{"solution":"C:\\\\Benutzer\\\\M\\u00fcller"}')
    assert_equal 'Pfad C:\\Temp "ok"', parse.call('{"solution":"Pfad C:\\\\Temp \\"ok\\""}')
  end

  # "C:\Temp\npruefen": path segment or line break? The ticket decides - the
  # finer levels copy paths verbatim from it.
  def test_ticket_text_decides_escape_like_segments
    ex = Extractor.new({})
    raw = '{"solution":"C:\\Temp\\npruefen"}'
    assert_equal "C:\\Temp\npruefen", ex.send(:parse_json, raw, 'Ordner C:\\Temp leeren')['solution']
    assert_equal 'C:\\Temp\\npruefen', ex.send(:parse_json, raw, 'Ordner C:\\Temp\\npruefen fehlt')['solution']
    # Case may differ between ticket and answer.
    assert_equal 'C:\\new\\test', ex.send(:parse_json, '{"solution":"C:\\new\\test"}', 'Pfad C:\\New\\Test')['solution']
  end

  def test_parse_repairs_paths_with_spaces
    parse = ->(raw) { Extractor.new({}).send(:parse_json, raw)['solution'] }
    assert_equal 'C:\\Program Files\\new\\test', parse.call('{"solution":"C:\\Program Files\\new\\test"}')
    assert_equal 'C:\\Program Files (x86)\\new', parse.call('{"solution":"C:\\Program Files (x86)\\new"}')
    assert_equal 'C:\\Users\\Max Mustermann\\Desktop', parse.call('{"solution":"C:\\Users\\Max Mustermann\\Desktop"}')
    # Prose after a path is not part of it - its line breaks stay.
    assert_equal "1. C:\\Temp leeren\nPruefen ob\n2. Neustart",
                 parse.call('{"solution":"1. C:\\Temp leeren\\nPruefen ob\\n2. Neustart"}')
  end

  # Solutions are full of real line breaks - also right after a path.
  def test_parse_keeps_line_breaks_and_tabs_outside_paths
    parse = ->(raw) { Extractor.new({}).send(:parse_json, raw)['solution'] }
    assert_equal "Schritt eins\nSchritt zwei\tTab", parse.call('{"solution":"Schritt eins\\nSchritt zwei\\tTab"}')
    assert_equal "1. C:\\Temp leeren\n2. Neustart", parse.call('{"solution":"1. C:\\\\Temp leeren\\n2. Neustart"}')
    assert_equal "1. C:\\Temp\n2. Neustart", parse.call('{"solution":"1. C:\\Temp\\n2. Neustart"}')
    assert_equal 'Meldung "DBX00101" kam', parse.call('{"solution":"Meldung \\"DBX00101\\" kam"}')
  end

  def test_parse_keeps_correctly_escaped_paths
    raw = '{"problem":"p","solution":"C:\\\\Program Files\\\\DATEV","has_solution":true}'
    assert_equal 'C:\\Program Files\\DATEV', Extractor.new({}).send(:parse_json, raw)['solution']
  end

  def test_finer_levels_ask_for_escaped_backslashes
    assert_includes Extractor.prompt_for('most_specific'), 'Backslash'
    assert_not_includes Extractor.prompt_for('general'), 'Backslash'
  end

  # --- extractor uses the project's prompt -------------------------------------

  def test_extract_sends_project_prompt_and_reports_level
    project = Project.find(1)
    HelpdeskProjectSetting.where(:project_id => project.id).delete_all
    HelpdeskProjectSetting.create!(:project_id => project.id, :kb_extract_detail => 'most_specific')
    issue = Issue.new(:project => project, :subject => 'Outlook 2016: Fehler 0x800CCC0E',
                      :description => 'Profil unter C:\\Users\\x\\AppData defekt.')

    RedmineExpertHelpdesk::AiClient.any_instance.stubs(:configured?).returns(true)
    RedmineExpertHelpdesk::AiClient.any_instance.stubs(:last_usage).returns(nil)
    RedmineExpertHelpdesk::AiClient.any_instance.expects(:summarize)
      .with { |prompt, _text, *_| prompt == Extractor.prompt_for('most_specific') }
      .returns('{"problem":"p","solution":"s","has_solution":true}')

    result = Extractor.new({}).extract(issue)
    assert_equal 'most_specific', result.detail
    assert result.has_solution
  end
end
