require File.expand_path('../../test_helper', __FILE__)

# Tests fuer die gemeinsame RAG-Suche von Zusammenfassung und Antwortvorschlag.
# Store und Client werden gestubbt - kein HTTP, keine Vektordatenbank.
class KnowledgeRetrievalTest < ActiveSupport::TestCase

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
  Retrieval = RedmineExpertHelpdesk::KnowledgeRetrieval

  def setup
    setup_plugin_settings_snapshot
    @issue = Issue.find(1)
    Setting.plugin_redmine_expert_helpdesk = Setting.plugin_redmine_expert_helpdesk.merge('kb_enabled' => '1')
  end

  def teardown
    restore_plugin_settings_snapshot
  end

  # Ein Store, der die uebergebenen Treffer zurueckgibt und Aufrufe mitschreibt.
  # asked captures the requested limit - with a reranker we over-fetch.
  def store_stub(hits, configured: true, asked: [])
    s = Object.new
    s.define_singleton_method(:configured?) { configured }
    s.define_singleton_method(:search) { |_pid, _vec, k| asked << k; hits }
    s
  end

  # rerank: nil = no reranker (the default, as before). Otherwise either a
  # lambda over the documents or a ready-made row list; :raise makes it fail.
  def client_stub(configured: true, calls: [], rerank: nil, reranked_docs: [])
    c = Object.new
    c.define_singleton_method(:embed_configured?) { configured }
    c.define_singleton_method(:embed) { |text, **_kw| calls << text; [0.1, 0.2] }
    c.define_singleton_method(:rerank_configured?) { !rerank.nil? }
    c.define_singleton_method(:rerank) do |_query, docs, **_kw|
      reranked_docs.replace(docs)
      raise RedmineExpertHelpdesk::AiClient::AiError, 'boom' if rerank == :raise

      rerank.respond_to?(:call) ? rerank.call(docs) : rerank
    end
    c
  end

  def row(index, score)
    { :index => index, :score => score }
  end

  def hit(issue_id, score, problem = 'P', solution = 'L')
    { :id => issue_id, :score => score,
      :payload => { 'issue_id' => issue_id, 'problem' => problem, 'solution' => solution } }
  end

  def settings(extra = {})
    { 'kb_top_k' => '3', 'kb_min_score' => '0.5', 'kb_min_results' => '1' }.merge(extra)
  end

  def test_returns_nothing_when_kb_is_globally_off
    Setting.plugin_redmine_expert_helpdesk = Setting.plugin_redmine_expert_helpdesk.merge('kb_enabled' => '0')
    calls = []
    assert_equal [], Retrieval.search(@issue, settings, client_stub(:calls => calls), 'Frage',
                                      :store => store_stub([hit(2, 0.9)]))
    # Kein Embedding-Aufruf: der globale Schalter kostet kein Geld.
    assert_equal [], calls
  end

  def test_returns_nothing_when_store_or_embedding_unconfigured
    calls = []
    assert_equal [], Retrieval.search(@issue, settings, client_stub(:calls => calls), 'Frage',
                                      :store => store_stub([hit(2, 0.9)], :configured => false))
    assert_equal [], Retrieval.search(@issue, settings, client_stub(:configured => false, :calls => calls),
                                      'Frage', :store => store_stub([hit(2, 0.9)]))
    assert_equal [], calls
  end

  def test_blank_query_is_not_embedded
    calls = []
    assert_equal [], Retrieval.search(@issue, settings, client_stub(:calls => calls), '   ',
                                      :store => store_stub([hit(2, 0.9)]))
    assert_equal [], calls
  end

  def test_hits_below_the_score_threshold_are_dropped
    hits = Retrieval.search(@issue, settings, client_stub, 'Frage',
                            :store => store_stub([hit(2, 0.9), hit(3, 0.2)]))
    assert_equal [2], hits.map { |h| h[:payload]['issue_id'] }
  end

  def test_explicit_min_score_overrides_the_setting
    hits = Retrieval.search(@issue, settings, client_stub, 'Frage',
                            :min_score => 0.95, :store => store_stub([hit(2, 0.9)]))
    assert_equal [], hits
  end

  # Das Ticket darf sich nicht selbst als Beleg fuer die eigene Antwort ziehen.
  def test_self_hit_is_rejected
    hits = Retrieval.search(@issue, settings, client_stub, 'Frage',
                            :store => store_stub([hit(@issue.id, 0.99)]))
    assert_equal [], hits
  end

  # Alles-oder-nichts: ein einzelner schwacher Treffer ist keine Grundlage.
  def test_min_results_is_all_or_nothing
    st = settings('kb_min_results' => '2')
    assert_equal [], Retrieval.search(@issue, st, client_stub, 'Frage',
                                      :store => store_stub([hit(2, 0.9)]))
    hits = Retrieval.search(@issue, st, client_stub, 'Frage',
                            :store => store_stub([hit(2, 0.9), hit(3, 0.8)]))
    assert_equal 2, hits.size
  end

  def test_store_error_is_swallowed_by_default
    boom = Object.new
    boom.define_singleton_method(:configured?) { true }
    boom.define_singleton_method(:search) { |*| raise RedmineExpertHelpdesk::KnowledgeStore::StoreError, 'weg' }
    assert_equal [], Retrieval.search(@issue, settings, client_stub, 'Frage', :store => boom)
  end

  # Der Antwortentwurf will den Unterschied sehen: "Store kaputt" ist nicht
  # dasselbe wie "kein passender Eintrag".
  def test_store_error_is_raised_when_requested
    boom = Object.new
    boom.define_singleton_method(:configured?) { true }
    boom.define_singleton_method(:search) { |*| raise RedmineExpertHelpdesk::KnowledgeStore::StoreError, 'weg' }
    assert_raises(RedmineExpertHelpdesk::KnowledgeStore::StoreError) do
      Retrieval.search(@issue, settings, client_stub, 'Frage', :store => boom, :raise_on_error => true)
    end
  end

  def test_format_hits_omits_ticket_numbers_for_the_customer_facing_draft
    text = Retrieval.format_hits([hit(4711, 0.9, 'Kasse bootet nicht', 'Netzteil getauscht')],
                                 :with_issue_ids => false)
    assert_includes text, 'Kasse bootet nicht'
    assert_includes text, 'Netzteil getauscht'
    assert_not_includes text, '4711'
  end

  def test_format_hits_names_the_ticket_for_the_internal_summary
    text = Retrieval.format_hits([hit(4711, 0.9)], :with_issue_ids => true)
    assert_includes text, '#4711'
  end

  # Ohne diese Zahl sehen "knapp verfehlt" und "nichts Passendes" von aussen
  # gleich aus - der Bearbeiter kann die Schwelle dann nicht beurteilen.
  def test_diagnostics_report_the_best_rejected_score
    diag = {}
    hits = Retrieval.search(@issue, settings, client_stub, 'Frage',
                            :min_score => 0.9, :store => store_stub([hit(2, 0.61), hit(3, 0.4)]),
                            :diagnostics => diag)
    assert_equal [], hits
    assert_in_delta 0.61, diag[:best_score], 0.0001
    assert_equal 2, diag[:candidates]
    assert_in_delta 0.9, diag[:threshold], 0.0001
  end

  # Der Selbsttreffer darf sich nicht als "bester Treffer" ausgeben.
  def test_diagnostics_ignore_the_self_hit
    diag = {}
    Retrieval.search(@issue, settings, client_stub, 'Frage',
                     :min_score => 0.9, :store => store_stub([hit(@issue.id, 0.99), hit(3, 0.5)]),
                     :diagnostics => diag)
    assert_in_delta 0.5, diag[:best_score], 0.0001
    assert_equal 1, diag[:candidates]
  end

  def test_diagnostics_are_optional
    assert_equal [], Retrieval.search(@issue, settings, client_stub, 'Frage',
                                      :min_score => 0.9, :store => store_stub([hit(2, 0.1)]))
  end

  # --- Reranking (second stage) -----------------------------------------

  def rerank_settings(extra = {})
    settings({ 'kb_rerank_candidates' => '20', 'kb_rerank_min_score' => '0.5' }.merge(extra))
  end

  def test_without_a_reranker_the_store_is_asked_for_top_k_only
    asked = []
    Retrieval.search(@issue, settings, client_stub, 'Frage',
                     :store => store_stub([hit(2, 0.9)], :asked => asked))
    assert_equal [3], asked
  end

  def test_reranker_over_fetches_candidates_from_the_store
    asked = []
    Retrieval.search(@issue, rerank_settings, client_stub(:rerank => [row(0, 0.9)]), 'Frage',
                     :store => store_stub([hit(2, 0.9)], :asked => asked))
    assert_equal [20], asked
  end

  def test_candidates_never_fall_below_top_k
    asked = []
    Retrieval.search(@issue, rerank_settings('kb_top_k' => '5', 'kb_rerank_candidates' => '2'),
                     client_stub(:rerank => [row(0, 0.9)]), 'Frage',
                     :store => store_stub([hit(2, 0.9)], :asked => asked))
    assert_equal [5], asked
  end

  def test_reranker_reorders_and_replaces_the_score
    # The vector store thinks 3 is the best hit, the reranker thinks 4.
    store = store_stub([hit(3, 0.9, 'Drucker'), hit(4, 0.6, 'Scanner')])
    client = client_stub(:rerank => [row(1, 0.95), row(0, 0.55)])
    hits = Retrieval.search(@issue, rerank_settings, client, 'Frage', :store => store)

    assert_equal [4, 3], hits.map { |h| h[:payload]['issue_id'] }
    assert_in_delta 0.95, hits.first[:score], 0.0001
    # Der Kosinus-Wert bleibt zur Diagnose erhalten.
    assert_in_delta 0.6, hits.first[:vector_score], 0.0001
  end

  def test_reranked_hits_are_gated_by_the_rerank_threshold_not_the_cosine_one
    # Cosine 0.9/0.9 would clear kb_min_score; the reranker rejects both.
    store = store_stub([hit(3, 0.9), hit(4, 0.9)])
    client = client_stub(:rerank => [row(0, 0.3), row(1, 0.2)])
    assert_equal [], Retrieval.search(@issue, rerank_settings, client, 'Frage', :store => store)
  end

  def test_a_low_cosine_hit_can_be_rescued_by_the_reranker
    # The reverse case: below kb_min_score, but the cross-encoder is certain.
    store = store_stub([hit(3, 0.2)])
    client = client_stub(:rerank => [row(0, 0.88)])
    hits = Retrieval.search(@issue, rerank_settings, client, 'Frage', :store => store)
    assert_equal [3], hits.map { |h| h[:payload]['issue_id'] }
  end

  def test_result_is_truncated_to_top_k_after_reranking
    store = store_stub([hit(3, 0.9), hit(4, 0.9), hit(5, 0.9), hit(6, 0.9)])
    client = client_stub(:rerank => [row(0, 0.9), row(1, 0.8), row(2, 0.7), row(3, 0.6)])
    hits = Retrieval.search(@issue, rerank_settings('kb_top_k' => '2'), client, 'Frage', :store => store)
    assert_equal 2, hits.size
  end

  # The reranker is an improvement, not a precondition.
  def test_a_failing_reranker_falls_back_to_vector_order_and_the_cosine_gate
    store = store_stub([hit(3, 0.9), hit(4, 0.6), hit(5, 0.2)])
    client = client_stub(:rerank => :raise)
    hits = Retrieval.search(@issue, rerank_settings, client, 'Frage', :store => store)

    # 0.2 faellt an kb_min_score (0.5) - nicht an kb_rerank_min_score.
    assert_equal [3, 4], hits.map { |h| h[:payload]['issue_id'] }
    assert_in_delta 0.9, hits.first[:score], 0.0001
    assert_nil hits.first[:vector_score]
  end

  def test_an_empty_rerank_response_falls_back_to_vector_order
    store = store_stub([hit(3, 0.9)])
    hits = Retrieval.search(@issue, rerank_settings, client_stub(:rerank => []), 'Frage', :store => store)
    assert_equal [3], hits.map { |h| h[:payload]['issue_id'] }
  end

  # Without the default the threshold would be 0.0 and let every hit through.
  def test_missing_rerank_min_score_setting_falls_back_to_the_default
    store = store_stub([hit(3, 0.9)])
    s = settings('kb_rerank_candidates' => '20') # kb_rerank_min_score deliberately unset
    assert_equal [], Retrieval.search(@issue, s, client_stub(:rerank => [row(0, 0.1)]), 'Frage',
                                      :store => store)
    hits = Retrieval.search(@issue, s, client_stub(:rerank => [row(0, 0.3)]), 'Frage',
                            :store => store)
    assert_equal [3], hits.map { |h| h[:payload]['issue_id'] }
  end

  # A typo in this free-form central setting must not silently remove the only
  # gate on the proposals. to_f would read "oops" as 0.0 and pass everything.
  def test_a_malformed_rerank_threshold_falls_back_to_the_default
    store = store_stub([hit(3, 0.9)])
    ['oops', '50%', 'NaN', '-0.5', '1.5', 'Infinity'].each do |bad|
      s = rerank_settings('kb_rerank_min_score' => bad)
      assert_equal [], Retrieval.search(@issue, s, client_stub(:rerank => [row(0, 0.1)]), 'Frage',
                                        :store => store),
                   "#{bad.inspect} should fall back to the 0.2 default, not disable the gate"
      hits = Retrieval.search(@issue, s, client_stub(:rerank => [row(0, 0.9)]), 'Frage',
                              :store => store)
      assert_equal [3], hits.map { |h| h[:payload]['issue_id'] },
                   "#{bad.inspect} should still admit a strong hit"
    end
  end

  # 0.0 is a legitimate value - "accept anything the reranker returns" - and must
  # survive, unlike a blank or a malformed one.
  def test_an_explicit_zero_rerank_threshold_is_honoured
    store = store_stub([hit(3, 0.9)])
    s = rerank_settings('kb_rerank_min_score' => '0.0')
    hits = Retrieval.search(@issue, s, client_stub(:rerank => [row(0, 0.05)]), 'Frage', :store => store)
    assert_equal [3], hits.map { |h| h[:payload]['issue_id'] }
  end

  def test_caller_min_score_overrides_the_rerank_threshold_too
    store = store_stub([hit(3, 0.9)])
    client = client_stub(:rerank => [row(0, 0.6)])
    assert_equal [], Retrieval.search(@issue, rerank_settings, client, 'Frage',
                                      :store => store, :min_score => 0.8)
    hits = Retrieval.search(@issue, rerank_settings, client, 'Frage',
                            :store => store, :min_score => 0.55)
    assert_equal [3], hits.map { |h| h[:payload]['issue_id'] }
  end

  # We do not pay to score a document that is going to be dropped anyway.
  def test_the_self_hit_is_dropped_before_the_reranker_sees_it
    docs = []
    store = store_stub([hit(@issue.id, 0.9, 'Eigenes'), hit(4, 0.8, 'Fremdes')])
    client = client_stub(:rerank => [row(0, 0.9)], :reranked_docs => docs)
    Retrieval.search(@issue, rerank_settings, client, 'Frage', :store => store)
    assert_equal ['Fremdes'], docs
  end

  def test_only_the_problem_text_is_reranked
    docs = []
    store = store_stub([hit(4, 0.8, 'Das Problem', 'Die Loesung')])
    client = client_stub(:rerank => [row(0, 0.9)], :reranked_docs => docs)
    Retrieval.search(@issue, rerank_settings, client, 'Frage', :store => store)
    assert_equal ['Das Problem'], docs
  end

  def test_min_results_still_applies_after_reranking
    store = store_stub([hit(3, 0.9), hit(4, 0.9)])
    client = client_stub(:rerank => [row(0, 0.9), row(1, 0.3)])
    # Only one hit survives the rerank threshold, but two are required.
    assert_equal [], Retrieval.search(@issue, rerank_settings('kb_min_results' => '2'),
                                      client, 'Frage', :store => store)
  end

  def test_diagnostics_report_the_rerank_stage
    store = store_stub([hit(3, 0.7)])
    client = client_stub(:rerank => [row(0, 0.35)])
    diag = {}
    assert_equal [], Retrieval.search(@issue, rerank_settings, client, 'Frage',
                                      :store => store, :diagnostics => diag)
    assert_equal true, diag[:reranked]
    assert_in_delta 0.35, diag[:best_score], 0.0001
    assert_in_delta 0.5, diag[:threshold], 0.0001
    assert_in_delta 0.7, diag[:best_vector_score], 0.0001
  end

  def test_diagnostics_say_when_reranking_did_not_happen
    diag = {}
    Retrieval.search(@issue, settings, client_stub, 'Frage',
                     :store => store_stub([hit(3, 0.9)]), :diagnostics => diag)
    assert_equal false, diag[:reranked]
  end
end
