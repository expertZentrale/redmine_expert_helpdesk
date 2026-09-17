require File.expand_path('../../test_helper', __FILE__)

# Tests fuer die gemeinsame RAG-Suche von Zusammenfassung und Antwortvorschlag.
# Store und Client werden gestubbt - kein HTTP, keine Vektordatenbank.
class KnowledgeRetrievalTest < ActiveSupport::TestCase
  Retrieval = RedmineExpertHelpdesk::KnowledgeRetrieval

  def setup
    @issue = Issue.find(1)
    Setting.plugin_redmine_expert_helpdesk = Setting.plugin_redmine_expert_helpdesk.merge('kb_enabled' => '1')
  end

  def teardown
    Setting.plugin_redmine_expert_helpdesk = Setting.plugin_redmine_expert_helpdesk.merge('kb_enabled' => '0')
  end

  # Ein Store, der die uebergebenen Treffer zurueckgibt und Aufrufe mitschreibt.
  def store_stub(hits, configured: true)
    s = Object.new
    s.define_singleton_method(:configured?) { configured }
    s.define_singleton_method(:search) { |_pid, _vec, _k| hits }
    s
  end

  def client_stub(configured: true, calls: [])
    c = Object.new
    c.define_singleton_method(:embed_configured?) { configured }
    c.define_singleton_method(:embed) { |text, **_kw| calls << text; [0.1, 0.2] }
    c
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
end
