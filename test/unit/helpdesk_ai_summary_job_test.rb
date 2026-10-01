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

  # Only explicit ticket references count. A bare number equal to the id (an
  # order number), or one that merely contains it, must not.
  def test_verdict_ignores_numbers_that_are_no_ticket_reference
    hits = [kb_hit(924_201, 0.83)]
    with_proposals(hits) do |issue|
      job.send(:record_ai_verdict, issue, hits, 'Auftrag 924201, Rufnummer 09242010, Beleg #9242010.')

      assert_equal false, HelpdeskKbProposal.find_by(:issue_id => issue.id).ai_verdict
    end
  end

  def test_verdict_accepts_ticket_without_hash
    hits = [kb_hit(924_201, 0.83)]
    with_proposals(hits) do |issue|
      job.send(:record_ai_verdict, issue, hits, 'Lösungsvorschlag (Ticket 924201): Call Queue.')

      assert_equal true, HelpdeskKbProposal.find_by(:issue_id => issue.id).ai_verdict
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

  # --- attachment text (extract_text) ---

  TextPs = Struct.new(:dummy) do
    def ai_attach_metadata?; false; end
    def ai_attach_text?; true; end
    def ai_attach_images?; false; end
  end

  FakeAttachment = Struct.new(:filename, :content_type, :diskfile, :filesize)

  def with_attachment(bytes, filename, content_type)
    file = Tempfile.new('ai-att')
    file.binmode
    file.write(bytes)
    file.close
    yield FakeAttachment.new(filename, content_type, file.path, bytes.bytesize)
  ensure
    file&.unlink
  end

  def build_with(att)
    job.send(:build_input, 'Siehe Anhang.', [att], TextPs.new, {}, nil, nil).first
  end

  # Field case #931581: Outlook labelled a forwarded .zip as text/plain; the
  # binary read met the UTF-8 prompt and the whole summary died with
  # Encoding::CompatibilityError.
  def test_binary_labelled_as_text_is_skipped
    zip = "PK\x03\x04\x14\x00\x08\x00\x08\x00\x80eXU\xC3\xFF".b
    with_attachment(zip, 'GO!_Stammdaten.zip', 'text/plain') do |att|
      input = build_with(att)
      assert_equal Encoding::UTF_8, input.encoding
      assert_equal 'Siehe Anhang.', input
    end
  end

  def test_skipped_binary_attachment_is_logged
    zip = "PK\x03\x04\x14\x00\x08\x00".b
    with_attachment(zip, 'GO!_Stammdaten.zip', 'text/plain') do |att|
      RedmineExpertHelpdesk::AiLogger.expects(:debug)
        .with(regexp_matches(/attachment-text issue=#42 file=GO!_Stammdaten\.zip type=text\/plain skipped=binary/))
      assert_nil job.send(:extract_text, att, Issue.new.tap { |i| i.id = 42 })
    end
  end

  def test_readable_text_attachment_is_not_logged
    with_attachment('Zählerstand 4711'.b, 'log.txt', 'text/plain') do |att|
      RedmineExpertHelpdesk::AiLogger.expects(:debug).never
      job.send(:extract_text, att)
    end
  end

  # A read with a length returns ASCII-8BIT even for real UTF-8, so every
  # text attachment with an umlaut crashed the same way.
  def test_utf8_text_attachment_is_included
    with_attachment('Grüße aus Köln – Zählerstand 4711'.b, 'log.txt', 'text/plain') do |att|
      input = build_with(att)
      assert_equal Encoding::UTF_8, input.encoding
      assert_includes input, 'Grüße aus Köln – Zählerstand 4711'
    end
  end

  def test_windows_1252_text_attachment_is_converted
    with_attachment("Gr\xFC\xDFe;Stra\xDFe".b, 'export.csv', 'text/csv') do |att|
      assert_includes build_with(att), 'Grüße;Straße'
    end
  end

  # Copilot review on PR #50: a short Windows-1252 file ending in a non-ASCII
  # byte looks like a cut UTF-8 character, but nothing was cut.
  def test_windows_1252_text_ending_in_an_umlaut_keeps_it
    with_attachment("Gr\xFC".b, 'short.txt', 'text/plain') do |att|
      assert_equal 'Grü', job.send(:extract_text, att)
    end
  end

  def test_multibyte_character_cut_at_the_read_limit_stays_utf8
    bytes = ('a' * (HelpdeskAiSummaryJob::MAX_ATT_TEXT_BYTES - 1) + 'ü' + 'rest').b
    with_attachment(bytes, 'long.txt', 'text/plain') do |att|
      text = job.send(:extract_text, att)
      assert_equal Encoding::UTF_8, text.encoding
      assert_equal 'a' * (HelpdeskAiSummaryJob::MAX_ATT_TEXT_BYTES - 1), text
    end
  end
end
