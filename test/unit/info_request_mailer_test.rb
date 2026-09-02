require File.expand_path('../../test_helper', __FILE__)

# Die Aufbereitung der Begruendungen ist der Teil, den der Kunde liest: Symbole
# aus dem Regelwerk werden lokalisiert, KI-Texte gehen unveraendert durch.
class InfoRequestMailerTest < ActiveSupport::TestCase
  Mailer = RedmineExpertHelpdesk::InfoRequestMailer

  def test_symbol_reasons_are_localised_and_bulleted
    rendered = Mailer.render_reasons([:too_short, :no_attachment])
    lines = rendered.split("\n")
    assert_equal 2, lines.size
    assert lines.all? { |l| l.start_with?('- ') }
    assert_equal I18n.t(:text_helpdesk_info_request_reason_too_short), lines[0].sub('- ', '')
  end

  def test_ai_reasons_pass_through
    assert_equal "- Fehlermeldung\n- Betroffenes System",
                 Mailer.render_reasons(['Fehlermeldung', 'Betroffenes System'])
  end

  def test_blank_reasons_are_dropped
    assert_equal '- Nur dieser', Mailer.render_reasons(['', '   ', 'Nur dieser'])
  end

  def test_empty_list_renders_empty_string
    assert_equal '', Mailer.render_reasons([])
    assert_equal '', Mailer.render_reasons(nil)
  end

  # Der Standardtext muss den Platzhalter enthalten, sonst erfaehrt der Kunde
  # nie, was eigentlich fehlt.
  def test_default_body_contains_missing_info_macro
    assert_includes Mailer::DEFAULT_BODY, '{{missing_info}}'
  end
end
