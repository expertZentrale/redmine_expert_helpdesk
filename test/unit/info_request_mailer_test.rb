require File.expand_path('../../test_helper', __FILE__)

# Rendering the reasons is the part the customer reads: symbols from the rule set
# are localised, AI texts pass through unchanged.
class InfoRequestMailerTest < ActiveSupport::TestCase
  fixtures :projects, :issues, :users, :trackers, :issue_statuses, :enumerations,
           :roles, :members, :member_roles

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

  # The default text must contain the placeholder, otherwise the customer never
  # learns what is actually missing.
  def test_default_body_contains_missing_info_macro
    assert_includes Mailer::DEFAULT_BODY, '{{missing_info}}'
  end

  # --- Template fallbacks: an empty mail must be impossible ---

  BlankSetting = Struct.new(:effective_info_request_body, :effective_info_request_subject,
                            :keyword_init => true)

  # An admin can clear the central setting, and a fresh install can miss the key,
  # which would otherwise mail the customer a completely empty body.
  def test_blank_body_falls_back_to_the_default
    setting = BlankSetting.new(:effective_info_request_body => '')
    assert_equal Mailer::DEFAULT_BODY, Mailer.body_template(setting)

    setting = BlankSetting.new(:effective_info_request_body => '   ')
    assert_equal Mailer::DEFAULT_BODY, Mailer.body_template(setting)
  end

  def test_configured_body_wins
    setting = BlankSetting.new(:effective_info_request_body => 'Eigener Text')
    assert_equal 'Eigener Text', Mailer.body_template(setting)
  end

  def test_blank_subject_falls_back_to_the_ticket_subject
    setting = BlankSetting.new(:effective_info_request_subject => '')
    template = Mailer.subject_template(setting, Issue.find(1))
    assert_includes template, '#1'
    assert_includes template, '{{issue.subject}}'
  end

  def test_configured_subject_wins
    setting = BlankSetting.new(:effective_info_request_subject => 'Rueckfrage')
    assert_equal 'Rueckfrage', Mailer.subject_template(setting, Issue.find(1))
  end

  # --- Visibility of the protocol note ---

  def add_note(private_note)
    issue = Issue.find(1)
    contact = HelpdeskContact.create!(:project_id => issue.project_id,
                                      :email => "note#{private_note}@example.com")
    Mailer.send(:add_note, issue, contact, '- Fehlermeldung', private_note)
    issue.journals.reload.last
  end

  def test_note_is_public_by_default
    assert_not add_note(false).private_notes?
  end

  def test_note_can_be_private
    assert add_note(true).private_notes?
  end

  # The reasons have to be in the note - otherwise the agent cannot see what the
  # customer was asked for.
  def test_note_contains_the_reasons
    assert_includes add_note(false).notes, '- Fehlermeldung'
  end
end
