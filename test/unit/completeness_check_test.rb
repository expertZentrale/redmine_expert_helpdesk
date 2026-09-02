require File.expand_path('../../test_helper', __FILE__)

# Tests fuer die Regelauswertung und das Parsen der KI-Antwort. Beides ist frei
# von DB/HTTP, daher genuegt hier ein Struct als Einstellungsobjekt.
class CompletenessCheckTest < ActiveSupport::TestCase
  Check = RedmineExpertHelpdesk::CompletenessCheck

  FakeSetting = Struct.new(:info_request_min_chars, :info_request_min_words,
                           :info_request_require_attachment, :info_request_keywords,
                           :info_request_threshold, :keyword_init => true) do
    def info_request_require_attachment?
      info_request_require_attachment ? true : false
    end
  end

  # Standard: nur die Laengenregel aktiv, Schwelle 1.
  def setting(**overrides)
    FakeSetting.new({
      :info_request_min_chars => 100,
      :info_request_min_words => 0,
      :info_request_require_attachment => false,
      :info_request_keywords => nil,
      :info_request_threshold => 1
    }.merge(overrides))
  end

  def test_long_mail_is_complete
    verdict = Check.evaluate(:text => 'x ' * 200, :setting => setting)
    assert verdict.complete?
    assert_empty verdict.reasons
    assert_equal 'heuristic', verdict.source
  end

  def test_short_mail_is_incomplete
    verdict = Check.evaluate(:text => 'Drucker geht nicht', :setting => setting)
    assert verdict.incomplete?
    assert_includes verdict.reasons, :too_short
  end

  def test_zero_disables_a_rule
    verdict = Check.evaluate(:text => 'kurz', :setting => setting(:info_request_min_chars => 0))
    assert verdict.complete?, 'min_chars = 0 muss die Regel abschalten'
  end

  def test_word_rule
    s = setting(:info_request_min_chars => 0, :info_request_min_words => 5)
    assert Check.evaluate(:text => 'eins zwei drei', :setting => s).incomplete?
    assert Check.evaluate(:text => 'eins zwei drei vier fuenf sechs', :setting => s).complete?
  end

  # Satzzeichen sind keine Woerter - sonst haette "a. b. c. d. e." fuenf Woerter.
  def test_word_rule_ignores_punctuation_only_tokens
    s = setting(:info_request_min_chars => 0, :info_request_min_words => 4)
    assert Check.evaluate(:text => 'Hilfe ! ? - :', :setting => s).incomplete?
  end

  def test_attachment_rule
    s = setting(:info_request_min_chars => 0, :info_request_require_attachment => true)
    assert Check.evaluate(:text => 'egal', :attachments => [], :setting => s).incomplete?
    assert Check.evaluate(:text => 'egal', :attachments => [:some_file], :setting => s).complete?
  end

  def test_keyword_rule_matches_case_insensitively
    s = setting(:info_request_min_chars => 0, :info_request_keywords => "Drucker\nSAP")
    assert Check.evaluate(:text => 'Der DRUCKER streikt', :setting => s).complete?
    assert Check.evaluate(:text => 'Der Bildschirm streikt', :setting => s).incomplete?
  end

  def test_keyword_rule_accepts_comma_separated_list
    s = setting(:info_request_min_chars => 0, :info_request_keywords => 'drucker, sap')
    assert_equal %w[drucker sap], Check.keyword_list(s)
  end

  # Schwelle 2: eine einzelne verletzte Regel darf noch keine Mail ausloesen.
  def test_threshold_requires_multiple_failures
    s = setting(:info_request_min_chars => 100, :info_request_require_attachment => true,
                :info_request_threshold => 2)
    assert Check.evaluate(:text => 'x' * 200, :attachments => [], :setting => s).complete?
    assert Check.evaluate(:text => 'kurz', :attachments => [], :setting => s).incomplete?
  end

  # 0 oder negativ wuerde sonst bei jeder Mail ausloesen.
  def test_threshold_zero_behaves_like_one
    s = setting(:info_request_threshold => 0)
    assert Check.evaluate(:text => 'x' * 200, :setting => s).complete?
    assert Check.evaluate(:text => 'kurz', :setting => s).incomplete?
  end

  # --- Zitierte Verlaeufe zaehlen nicht als eigene Information ---

  def test_quoted_history_is_stripped
    text = "Geht immer noch nicht.\n\n" + ('> alter Verlauf ' * 100)
    assert Check.evaluate(:text => text, :setting => setting).incomplete?
  end

  def test_forwarded_header_is_stripped
    text = "Bitte pruefen.\n-----Urspruengliche Nachricht-----\n" + ('Blah ' * 200)
    assert Check.evaluate(:text => text, :setting => setting).incomplete?
  end

  def test_signature_delimiter_is_stripped
    text = "Hilfe!\n-- \n" + ('Max Mustermann, Musterfirma GmbH ' * 30)
    assert Check.evaluate(:text => text, :setting => setting).incomplete?
  end

  def test_meaningful_text_normalises_whitespace
    assert_equal 'a b c', Check.meaningful_text("a\r\n  b\t\tc  ")
  end

  # --- KI-Antwort ---

  def test_parse_clean_json_incomplete
    verdict = Check.parse_ai_verdict('{"complete": false, "missing": ["Fehlermeldung"]}')
    assert verdict.incomplete?
    assert_equal ['Fehlermeldung'], verdict.reasons
    assert_equal 'ai', verdict.source
  end

  def test_parse_clean_json_complete
    verdict = Check.parse_ai_verdict('{"complete": true, "missing": []}')
    assert verdict.complete?
    assert_equal 'ai', verdict.source
  end

  def test_parse_fenced_json
    raw = "Hier das Ergebnis:\n```json\n{\"complete\": false, \"missing\": [\"System\"]}\n```"
    verdict = Check.parse_ai_verdict(raw)
    assert verdict.incomplete?
    assert_equal ['System'], verdict.reasons
  end

  # Alles Unlesbare muss als "vollstaendig" gelten - eine kaputte Modellantwort
  # darf niemals eine Mail an den Kunden ausloesen.
  def test_parse_fails_closed_on_garbage
    ['', 'Tut mir leid, ich kann das nicht.', '{kein json', 'null', '[]'].each do |raw|
      verdict = Check.parse_ai_verdict(raw)
      assert verdict.complete?, "#{raw.inspect} haette keine Rueckfrage ausloesen duerfen"
      assert_equal 'error', verdict.source
    end
  end

  def test_parse_fails_closed_without_complete_field
    verdict = Check.parse_ai_verdict('{"missing": ["irgendwas"]}')
    assert verdict.complete?
    assert_equal 'error', verdict.source
  end

  # "unvollstaendig" ohne Begruendung gibt dem Kunden nichts zu beantworten.
  def test_parse_fails_closed_on_incomplete_without_reasons
    verdict = Check.parse_ai_verdict('{"complete": false, "missing": []}')
    assert verdict.complete?
    assert_equal 'error', verdict.source
  end

  def test_parse_accepts_stringified_booleans
    assert Check.parse_ai_verdict('{"complete": "true"}').complete?
    assert Check.parse_ai_verdict('{"complete": "false", "missing": ["x"]}').incomplete?
  end
end
