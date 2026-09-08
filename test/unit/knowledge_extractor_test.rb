require File.expand_path('../../test_helper', __FILE__)

# Tests fuer das tolerante JSON-Parsing des KnowledgeExtractor.
class KnowledgeExtractorTest < ActiveSupport::TestCase
  def extractor
    RedmineExpertHelpdesk::KnowledgeExtractor.new({})
  end

  # The subject often carries the device and the error the body only refers to.
  def test_ticket_text_starts_with_the_subject
    issue = Issue.new(:subject => '  Drucker HP 4050: Fehler 49.4C02 ', :description => 'Geht nicht.')
    text = extractor.send(:ticket_text, issue)
    assert text.start_with?("Betreff: Drucker HP 4050: Fehler 49.4C02\n\nGeht nicht."), text
  end

  def test_ticket_text_without_subject_has_no_marker
    issue = Issue.new(:subject => '', :description => 'Geht nicht.')
    assert_equal 'Geht nicht.', extractor.send(:ticket_text, issue)
  end

  def test_default_prompt_mentions_the_subject
    assert_includes RedmineExpertHelpdesk::KnowledgeExtractor::DEFAULT_PROMPT, 'Betreff:'
  end

  def test_parse_plain_json
    d = extractor.send(:parse_json, '{"problem":"p","solution":"s","has_solution":true}')
    assert_equal 'p', d['problem']
    assert_equal true, d['has_solution']
  end

  def test_parse_code_fenced_json
    raw = "```json\n{\"problem\":\"p\",\"solution\":\"s\",\"has_solution\":true}\n```"
    assert_equal 's', extractor.send(:parse_json, raw)['solution']
  end

  def test_parse_json_embedded_in_text
    raw = "Hier das JSON:\n{\"problem\":\"p\",\"has_solution\":false}\nDanke."
    assert_equal false, extractor.send(:parse_json, raw)['has_solution']
  end

  def test_parse_invalid_returns_nil
    assert_nil extractor.send(:parse_json, 'kein json hier')
  end
end
