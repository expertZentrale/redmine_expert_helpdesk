require File.expand_path('../../test_helper', __FILE__)

# Tests fuer die Gate-Logik des KI-Jobs: ohne globale Aktivierung wird kein
# Client erzeugt und keine Notiz geschrieben.
class HelpdeskAiSummaryJobTest < ActiveSupport::TestCase
  # Attachment switches off: only the text path matters here.
  FakePs = Struct.new(:ai_attach_metadata, :ai_attach_text, :ai_attach_images) do
    def ai_attach_metadata?; false; end
    def ai_attach_text?; false; end
    def ai_attach_images?; false; end
  end

  def job
    HelpdeskAiSummaryJob.new
  end

  def build(text, subject: nil, max: 12_000)
    job.send(:build_input, text, [], FakePs.new, { 'ai_max_input_chars' => max.to_s },
             nil, nil, :subject => subject).first
  end

  # --- The subject line is part of the model input ---

  def test_build_input_puts_the_subject_first
    input = build('Bitte um Hilfe.', :subject => ' Drucker HP 4050 druckt nicht ')
    assert_equal "Betreff: Drucker HP 4050 druckt nicht\n\nBitte um Hilfe.", input
  end

  def test_build_input_without_subject_is_unchanged
    assert_equal 'Bitte um Hilfe.', build('Bitte um Hilfe.')
    assert_equal 'Bitte um Hilfe.', build('Bitte um Hilfe.', :subject => '  ')
  end

  # The subject is the head of the text, so the input limit cuts the body, never
  # the subject.
  def test_truncation_keeps_the_subject
    input = build('x' * 500, :subject => 'Drucker', :max => 30)
    assert input.start_with?("Betreff: Drucker\n\nxxx"), input
    assert_equal 30, input.length
  end

  # The actual problem: a long subject over a one-line body was skipped as
  # "too short to summarize".
  def test_subject_counts_towards_the_minimum_length
    settings = { 'ai_min_input_chars' => '60' }
    subject = 'Drucker HP 4050 im Erdgeschoss druckt seit heute frueh nicht mehr, Fehler 49.4C02'
    assert job.send(:too_short?, job.send(:with_subject, nil, 'Bitte um Hilfe.'), settings)
    assert_not job.send(:too_short?, job.send(:with_subject, subject, 'Bitte um Hilfe.'), settings)
  end

  # Without an .eml the subject comes from the issue.
  def test_source_subject_falls_back_to_the_issue
    issue = Issue.new(:subject => '  Drucker kaputt ')
    assert_equal 'Drucker kaputt', job.send(:source_subject, issue, nil)
  end

  # The job labels the subject with this marker - the prompt must explain it.
  def test_default_prompt_mentions_the_subject
    assert_includes RedmineExpertHelpdesk::AiClient::DEFAULT_PROMPT, 'Betreff:'
  end

  def test_skips_when_globally_disabled
    Setting.stubs(:plugin_redmine_expert_helpdesk).returns({ 'ai_enabled' => '0' })
    # Kein Client, keine Issue-Suche, wenn global aus.
    RedmineExpertHelpdesk::AiClient.expects(:new).never
    Issue.expects(:find_by).never
    assert_nothing_raised { HelpdeskAiSummaryJob.perform_now(999_999) }
  end

  def test_swallows_errors_and_never_raises
    # Global an, aber Issue existiert nicht -> Job endet ruhig (kein Raise).
    Setting.stubs(:plugin_redmine_expert_helpdesk).returns({ 'ai_enabled' => '1' })
    assert_nothing_raised { HelpdeskAiSummaryJob.perform_now(-1) }
  end

  # --- The sidebar follows the summary's choice (record_ai_verdict) ---

  def kb_hit(issue_id, score)
    { :score => score, :payload => { 'issue_id' => issue_id, 'problem' => "P#{issue_id}", 'solution' => "L#{issue_id}" } }
  end

  def with_proposals(hits, reranked = nil)
    issue = Issue.first
    job.send(:persist_proposals, issue, hits, reranked)
    yield issue
  ensure
    HelpdeskKbProposal.where(:issue_id => Issue.first.id).delete_all
  end

  # The field case: retrieval ranked 919297 first, the summary cited 924201.
  def test_verdict_marks_what_the_summary_cited
    hits = [kb_hit(919_297, 0.84), kb_hit(924_201, 0.83), kb_hit(922_603, 0.81)]
    with_proposals(hits) do |issue|
      job.send(:record_ai_verdict, issue, hits,
               "- Anliegen: ...\n- Lösungsvorschlag (Ticket #924201): Call Queue öffnen, Mitarbeiterin hinzufügen.")
      verdicts = HelpdeskKbProposal.where(:issue_id => issue.id).pluck(:source_issue_id, :ai_verdict).to_h

      assert_equal({ 919_297 => false, 924_201 => true, 922_603 => false }, verdicts)
    end
  end

  def test_verdict_marks_all_as_unfit_when_nothing_is_cited
    hits = [kb_hit(919_297, 0.84), kb_hit(924_201, 0.83)]
    with_proposals(hits) do |issue|
      job.send(:record_ai_verdict, issue, hits, "- Anliegen: Sammelrufnummer 261, Durchwahl 8261.")

      assert_equal [false], HelpdeskKbProposal.where(:issue_id => issue.id).distinct.pluck(:ai_verdict)
    end
  end

  # Only whole numbers that are a proposal's own ticket count: 9242010 or a
  # phone number containing 924201 must not.
  def test_verdict_ignores_numbers_that_only_contain_a_ticket_id
    hits = [kb_hit(924_201, 0.83)]
    with_proposals(hits) do |issue|
      job.send(:record_ai_verdict, issue, hits, 'Rufnummer 09242010 und Auftrag 1924201.')

      assert_equal false, HelpdeskKbProposal.find_by(:issue_id => issue.id).ai_verdict
    end
  end

  def test_proposals_carry_the_reranked_flag
    with_proposals([kb_hit(1, 0.5)], false) do |issue|
      assert_equal false, HelpdeskKbProposal.find_by(:issue_id => issue.id).reranked
    end
    with_proposals([kb_hit(1, 0.5)]) do |issue|
      assert_nil HelpdeskKbProposal.find_by(:issue_id => issue.id).reranked
    end
  end
end
