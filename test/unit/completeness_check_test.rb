require File.expand_path('../../test_helper', __FILE__)

# Tests fuer die Regelauswertung und das Parsen der KI-Antwort. Beides ist frei
# von DB/HTTP, daher genuegt hier ein Struct als Einstellungsobjekt.
class CompletenessCheckTest < ActiveSupport::TestCase
  Check = RedmineExpertHelpdesk::CompletenessCheck

  FakeSetting = Struct.new(:info_request_min_chars, :info_request_min_words,
                           :info_request_require_attachment, :info_request_keywords,
                           :info_request_threshold, :info_request_min_attachment_kb,
                           :keyword_init => true) do
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
      :info_request_threshold => 1,
      :info_request_min_attachment_kb => Check::DEFAULT_MIN_ATTACHMENT_KB
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
    assert Check.evaluate(:text => 'egal', :attachments => [png(300)], :setting => s).complete?
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

  # --- Anhang-Inventar fuer den KI-Modus ---

  FakeAttachment = Struct.new(:filename, :content_type, :filesize)

  def png(kb)
    FakeAttachment.new('bild.png', 'image/png', kb * 1024)
  end

  # Ohne diese Liste wuerde das Modell einen Screenshot verlangen, den der Kunde
  # laengst mitgeschickt hat.
  def test_inventory_lists_name_and_type
    inv = Check.attachment_inventory([FakeAttachment.new('fehler.png', 'image/png', 400 * 1024),
                                      FakeAttachment.new('log.txt', 'text/plain', 900)])
    assert_includes inv, 'Anhaenge dieser Mail:'
    assert_includes inv, 'fehler.png (image/png)'
    assert_includes inv, 'log.txt (text/plain)'
  end

  def test_inventory_says_none_when_empty
    assert_includes Check.attachment_inventory([]), 'keine'
    assert_includes Check.attachment_inventory(nil), 'keine'
  end

  def test_inventory_omits_missing_content_type
    inv = Check.attachment_inventory([FakeAttachment.new('foto.jpg', nil, 800 * 1024)])
    assert_includes inv, 'foto.jpg'
    assert_not_includes inv, '('
  end

  def test_inventory_skips_nameless_attachments
    inv = Check.attachment_inventory([FakeAttachment.new('', 'image/png', 400 * 1024),
                                      FakeAttachment.new('da.png', 'image/png', 400 * 1024)])
    assert_includes inv, 'da.png'
    assert_not_includes inv, ', '
  end

  # Der Prompt verspricht diesen Abschnitt - fehlt er, laeuft die Anweisung ins Leere.
  def test_default_prompt_and_inventory_agree_on_the_marker
    assert_includes Check::DEFAULT_AI_PROMPT, 'Anhaenge dieser Mail:'
    assert_includes Check.attachment_inventory([]), 'Anhaenge dieser Mail:'
  end

  # Screenshot fuer Software, Foto fuer Hardware - beides muss im Prompt stehen.
  def test_default_prompt_asks_for_screenshot_and_photo
    prompt = Check::DEFAULT_AI_PROMPT
    assert_includes prompt, 'SCREENSHOT'
    assert_includes prompt, 'SOFTWARE'
    assert_includes prompt, 'FOTO'
    assert_includes prompt, 'HARDWARE'
  end

  # --- Zu kleine Bilder zaehlen nicht als Screenshot/Foto ---

  # Das eigentliche Problem: das Signatur-Logo haengt an fast jeder Mail und
  # wuerde "Anhang erforderlich" sonst immer erfuellen.
  def test_signature_logo_does_not_satisfy_the_attachment_rule
    s = setting(:info_request_min_chars => 0, :info_request_require_attachment => true)
    verdict = Check.evaluate(:text => 'egal', :attachments => [png(3)], :setting => s)
    assert verdict.incomplete?
    assert_includes verdict.reasons, :no_attachment
  end

  def test_real_screenshot_satisfies_the_attachment_rule
    s = setting(:info_request_min_chars => 0, :info_request_require_attachment => true)
    assert Check.evaluate(:text => 'egal', :attachments => [png(400)], :setting => s).complete?
  end

  # Die Schwelle gilt nur fuer Bilder - ein kleines Log ist echtes Beweismaterial.
  def test_small_non_image_still_counts
    s = setting(:info_request_min_chars => 0, :info_request_require_attachment => true)
    log = FakeAttachment.new('error.log', 'text/plain', 900)
    assert Check.evaluate(:text => 'egal', :attachments => [log], :setting => s).complete?
  end

  def test_threshold_is_configurable
    s = setting(:info_request_min_chars => 0, :info_request_require_attachment => true,
                :info_request_min_attachment_kb => 500)
    assert Check.evaluate(:text => 'x', :attachments => [png(400)], :setting => s).incomplete?
    assert Check.evaluate(:text => 'x', :attachments => [png(600)], :setting => s).complete?
  end

  def test_zero_threshold_accepts_any_image
    s = setting(:info_request_min_chars => 0, :info_request_require_attachment => true,
                :info_request_min_attachment_kb => 0)
    assert Check.evaluate(:text => 'x', :attachments => [png(1)], :setting => s).complete?
  end

  # Ohne Content-Type entscheidet die Endung.
  def test_extension_identifies_images_without_content_type
    small = FakeAttachment.new('logo.png', nil, 2 * 1024)
    assert_empty Check.relevant_attachments([small])
  end

  # Unbekannte Groesse: im Zweifel behalten, nicht verwerfen.
  def test_unknown_size_is_kept
    unknown = FakeAttachment.new('bild.png', 'image/png', nil)
    assert_equal 1, Check.relevant_attachments([unknown]).size
  end

  # Das Inventar fuer die KI darf die gefilterten Bilder nicht doch nennen.
  def test_inventory_hides_filtered_images
    inv = Check.attachment_inventory([png(2), FakeAttachment.new('echt.png', 'image/png', 300 * 1024)])
    assert_includes inv, 'echt.png'
    assert_not_includes inv, 'bild.png'
  end

  def test_inventory_says_none_when_only_logos_are_attached
    assert_includes Check.attachment_inventory([png(2)]), 'keine'
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
