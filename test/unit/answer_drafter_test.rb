require File.expand_path('../../test_helper', __FILE__)

# Tests fuer den kundengerichteten Antwortvorschlag. Geprueft wird vor allem,
# was NICHT im Prompt landet: interne Notizen und fremde Ticketnummern.
class AnswerDrafterTest < ActiveSupport::TestCase

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

  def setup
    setup_plugin_settings_snapshot
  end

  def teardown
    restore_plugin_settings_snapshot
  end
  Drafter = RedmineExpertHelpdesk::AnswerDrafter

  def drafter(extra = {})
    Drafter.new({ 'ai_max_input_chars' => '12000' }.merge(extra))
  end

  def hit(issue_id, score, problem = 'Kasse bootet nicht', solution = 'Netzteil getauscht')
    { :id => issue_id, :score => score,
      :payload => { 'issue_id' => issue_id, 'problem' => problem, 'solution' => solution } }
  end

  # --- Varianten ----------------------------------------------------------

  def test_every_variant_has_a_label_key_in_both_locales
    Drafter::VARIANTS.each_key do |key|
      assert I18n.t(:"label_helpdesk_ai_answer_variant_#{key}", :locale => :en, :default => nil).present?, key
      assert I18n.t(:"label_helpdesk_ai_answer_variant_#{key}", :locale => :de, :default => nil).present?, key
    end
  end

  def test_unknown_variant_falls_back_to_standard
    assert_equal 'standard', Drafter.variant_key('nonsense')
    assert_equal 'standard', Drafter.variant_key(nil)
    assert_equal 'steps', Drafter.variant_key('steps')
  end

  # Nur die Rueckfrage darf ohne Wissensbasis-Treffer laufen: sie schlaegt
  # nichts vor, sie fragt nach.
  def test_only_the_ask_variant_works_without_grounding
    assert Drafter.needs_grounding?('standard')
    assert Drafter.needs_grounding?('steps')
    assert Drafter.needs_grounding?('short')
    assert_not Drafter.needs_grounding?('ask')
  end

  def test_variant_suffix_reaches_the_prompt
    issue = Issue.new(:subject => 'Kasse 3', :description => 'Geht nicht.')
    prompt = drafter.send(:system_prompt, issue, nil, 'steps', [])
    assert_includes prompt, 'Schritt-fuer-Schritt'
    prompt = drafter.send(:system_prompt, issue, nil, 'ask', [])
    assert_includes prompt, 'Rueckfrage'
    assert_includes prompt, 'KEINE Loesung'
  end

  # --- Wissensbasis-Block -------------------------------------------------

  def test_kb_block_carries_content_but_no_ticket_numbers
    block = drafter.send(:kb_block, [hit(4711, 0.9)])
    assert_includes block, 'Kasse bootet nicht'
    assert_includes block, 'Netzteil getauscht'
    assert_not_includes block, '4711'
    assert_includes block, Drafter::NO_DRAFT_TOKEN
  end

  def test_kb_block_is_absent_without_hits
    assert_nil drafter.send(:kb_block, [])
  end

  # --- Rahmen (Anrede/Signatur) ------------------------------------------

  def test_frame_block_asks_for_a_salutation_when_no_mailbox_is_present
    issue = Issue.find(1)
    d = drafter
    d.define_singleton_method(:mailbox_for) { |_i| nil }
    frame = d.send(:frame_block, issue, {})
    assert_includes frame, 'kein Kopftext'
    assert_includes frame, 'kein Fusstext'
  end

  def test_frame_block_quotes_a_configured_header_and_footer
    issue = Issue.find(1)
    mailbox = Object.new
    mailbox.define_singleton_method(:reply_header) { 'Guten Tag,' }
    mailbox.define_singleton_method(:effective_footer_template) { 'Mit freundlichen Gruessen' }
    d = drafter
    d.define_singleton_method(:mailbox_for) { |_i| mailbox }
    frame = d.send(:frame_block, issue, {})
    assert_includes frame, 'Guten Tag,'
    assert_includes frame, 'Mit freundlichen Gruessen'
    assert_includes frame, 'VORANGESTELLT'
    assert_includes frame, 'ANGEHAENGT'
    # Genau der Punkt: das Modell soll keine zweite Anrede schreiben.
    assert_includes frame, 'beginne nicht mit einer eigenen Anrede'
  end

  # --- Eingabetext --------------------------------------------------------

  def test_ticket_text_excludes_private_notes
    issue = Issue.find(1)
    Journal.create!(:journalized => issue, :user => User.find(1), :notes => 'OEFFENTLICH')
    Journal.create!(:journalized => issue, :user => User.find(1), :notes => 'INTERN', :private_notes => true)
    issue.reload

    text = drafter.send(:ticket_text, issue)
    assert_includes text, 'OEFFENTLICH'
    assert_not_includes text, 'INTERN'
  end

  def test_extractor_still_sees_private_notes
    issue = Issue.find(1)
    Journal.create!(:journalized => issue, :user => User.find(1), :notes => 'INTERN', :private_notes => true)
    issue.reload

    text = RedmineExpertHelpdesk::KnowledgeExtractor.ticket_text(issue)
    assert_includes text, 'INTERN'
  end

  def test_ticket_text_starts_with_the_subject_and_is_truncated
    issue = Issue.find(1)
    issue.update_columns(:subject => 'Kasse 3 bootet nicht', :description => 'x' * 500)
    text = drafter('ai_max_input_chars' => '80').send(:ticket_text, issue.reload)
    assert text.start_with?('Betreff: Kasse 3 bootet nicht'), text
    assert_equal 80, text.length
  end

  # --- Aufbereitung der Modellausgabe -------------------------------------

  def test_sanitize_strips_fences_preamble_and_invented_subject
    d = drafter
    assert_equal 'Guten Tag', d.send(:sanitize, "```\nGuten Tag\n```")
    assert_equal 'Guten Tag', d.send(:sanitize, "Hier ist der Entwurf:\n\nGuten Tag")
    assert_equal 'Guten Tag', d.send(:sanitize, "Betreff: Ihre Anfrage\nGuten Tag")
  end

  # --- Verfuegbarkeit -----------------------------------------------------

  def test_not_available_without_a_contact
    assert_not Drafter.available_for?(Project.find(1), nil)
  end

  def test_not_available_while_globally_off
    Setting.plugin_redmine_expert_helpdesk =
      Setting.plugin_redmine_expert_helpdesk.merge('ai_enabled' => '1', 'ai_answer_enabled' => '0')
    assert_not Drafter.available_for?(Project.find(1), HelpdeskContact.new(:email => 'a@b.de'))
  end

  def test_menu_variants_are_empty_when_unavailable
    assert_equal [], Drafter.menu_variants(Project.find(1), nil)
  end

  # Der Entwurf muss "Wissensbasis aus" von "nichts gefunden" unterscheiden.
  def test_grounding_raises_when_the_knowledge_base_is_switched_off
    Setting.plugin_redmine_expert_helpdesk =
      Setting.plugin_redmine_expert_helpdesk.merge('kb_enabled' => '0')
    d = drafter
    assert_raises(Drafter::KbUnavailableError) do
      d.send(:grounding_hits, Issue.find(1), 'Kasse bootet nicht', User.find(1))
    end
  end

  # --- Mindest-Uebereinstimmung ------------------------------------------

  def test_min_score_falls_back_to_the_shipped_default
    assert_equal Drafter::DRAFT_MIN_SCORE, drafter.send(:min_score_for, Issue.find(1))
  end

  def test_central_min_score_is_used_when_no_project_value_is_set
    Setting.plugin_redmine_expert_helpdesk =
      Setting.plugin_redmine_expert_helpdesk.merge('ai_answer_min_score' => '0.8')
    ps = HelpdeskProjectSetting.find_or_initialize_by(:project_id => 1)
    ps.ai_answer_min_score = nil
    ps.save!
    assert_in_delta 0.8, drafter.send(:min_score_for, Issue.find(1)), 0.0001
  end

  # Ein Projekt mit kleiner Wissensbasis darf strenger sein als der Rest.
  def test_project_min_score_overrides_the_central_value
    Setting.plugin_redmine_expert_helpdesk =
      Setting.plugin_redmine_expert_helpdesk.merge('ai_answer_min_score' => '0.65')
    ps = HelpdeskProjectSetting.find_or_initialize_by(:project_id => 1)
    ps.ai_answer_min_score = 0.9
    ps.save!
    assert_in_delta 0.9, drafter.send(:min_score_for, Issue.find(1)), 0.0001
  end

  # Ein Tippfehler in den Einstellungen darf die Belegpflicht nicht abschalten.
  def test_min_score_is_clamped_to_zero_and_one
    ps = HelpdeskProjectSetting.find_or_initialize_by(:project_id => 1)
    ps.ai_answer_min_score = nil
    ps.save!
    Setting.plugin_redmine_expert_helpdesk =
      Setting.plugin_redmine_expert_helpdesk.merge('ai_answer_min_score' => '42')
    assert_equal 1.0, drafter.send(:min_score_for, Issue.find(1))
  end

  def test_project_min_score_outside_zero_to_one_is_rejected
    ps = HelpdeskProjectSetting.new(:project_id => 1, :ai_answer_min_score => 1.5)
    assert_not ps.valid?
    assert ps.errors[:ai_answer_min_score].present?
  end

  def test_no_grounding_error_carries_the_best_rejected_score
    e = Drafter::NoGroundingError.new(:best_score => 0.61, :threshold => 0.65)
    assert_in_delta 0.61, e.best_score, 0.0001
    assert_in_delta 0.65, e.threshold, 0.0001
  end

  # Ein gespeicherter, nie versendeter Entwurf darf nicht als Loesung
  # zurueck in die Wissensbasis wandern (Copilot-Review zu PR #29).
  def test_saved_draft_journal_is_excluded_from_knowledge_base_input
    issue = Issue.find(1)
    keep  = Journal.create!(:journalized => issue, :user => User.find(1), :notes => 'ECHTE LOESUNG')
    draft = Journal.create!(:journalized => issue, :user => User.find(1), :notes => 'KI ENTWURF TEXT')
    HelpdeskAiDraftedJournal.create!(:journal_id => draft.id, :issue_id => issue.id, :user_id => 1)
    issue.reload

    text = RedmineExpertHelpdesk::KnowledgeExtractor.ticket_text(issue)
    assert_includes text, 'ECHTE LOESUNG'
    assert_not_includes text, 'KI ENTWURF TEXT'
    assert_equal [draft.id], HelpdeskAiDraftedJournal.journal_ids_for(issue.id)
  end

  def test_saved_manual_note_is_not_marked_by_a_stale_ai_flag
    issue = Issue.find(1)
    note  = Journal.create!(:journalized => issue, :user => User.find(1), :notes => 'VON HAND')

    RedmineExpertHelpdesk::Hooks.new.controller_issues_edit_after_save(
      :journal => note,
      :issue => issue,
      :params => { :hd_ai_drafted => '1', :hd_ai_draft_base_text => "VON HAND\r\n" }
    )

    assert_empty HelpdeskAiDraftedJournal.where(:journal_id => note.id)
  end

  def test_saved_edited_draft_stays_marked_for_knowledge_base_exclusion
    issue = Issue.find(1)
    note  = Journal.create!(:journalized => issue, :user => User.find(1), :notes => 'KI ENTWURF, VON HAND UEBERARBEITET')

    RedmineExpertHelpdesk::Hooks.new.controller_issues_edit_after_save(
      :journal => note,
      :issue => issue,
      :params => { :hd_ai_drafted => '1', :hd_ai_draft_base_text => 'MANUELLE VORNOTIZ' }
    )

    assert_equal [note.id], HelpdeskAiDraftedJournal.where(:journal_id => note.id).pluck(:journal_id)
  end
end
