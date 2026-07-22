require File.expand_path('../../test_helper', __FILE__)

# Tests fuer den Vektor-Store: Backend-Auswahl, Qdrant-Request-Formen und die
# zwingende Projekt-Bindung im pgvector-Suchpfad.
class KnowledgeStoreTest < ActiveSupport::TestCase
  Store = RedmineExpertHelpdesk::KnowledgeStore

  def test_factory_picks_backend
    assert_instance_of Store::QdrantStore,   Store.for({ 'kb_backend' => 'qdrant' })
    assert_instance_of Store::PgvectorStore, Store.for({ 'kb_backend' => 'pgvector' })
    assert_instance_of Store::QdrantStore,   Store.for({}) # default
  end

  def test_qdrant_collection_naming_and_configured
    s = Store::QdrantStore.new({ 'kb_qdrant_url' => 'http://q:6333' })
    assert s.configured?
    assert_equal 'helpdesk_kb_p42', s.collection(42)
    assert_not Store::QdrantStore.new({}).configured?
  end

  def test_qdrant_search_shape
    s = Store::QdrantStore.new({ 'kb_qdrant_url' => 'http://q:6333' })
    captured = {}
    s.define_singleton_method(:request) do |method, path, payload = nil, allow_404: false|
      captured.merge!(:method => method, :path => path, :payload => payload)
      { 'result' => [{ 'id' => 5, 'score' => 0.9,
                       'payload' => { 'issue_id' => 5, 'problem' => 'p', 'solution' => 's' } }] }
    end
    res = s.search(42, [0.1, 0.2], 3)
    assert_equal '/collections/helpdesk_kb_p42/points/search', captured[:path]
    assert_equal [0.1, 0.2], captured[:payload][:vector]
    assert_equal 1, res.size
    assert_equal 0.9, res.first[:score]
    assert_equal 5, res.first[:payload]['issue_id']
  end

  def test_pgvector_search_always_binds_project_id
    s = Store::PgvectorStore.new({ 'kb_pg_url' => 'postgres://x' })
    captured = {}
    fake = Object.new
    fake.define_singleton_method(:exec_params) do |sql, params|
      captured.merge!(:sql => sql, :params => params)
      []
    end
    s.define_singleton_method(:conn) { fake }
    s.search(42, [0.1, 0.2], 3)
    assert_includes captured[:sql], 'WHERE project_id = $1'
    assert_equal 42, captured[:params][0]
    assert_includes captured[:params][1], '[0.1,0.2]'
    assert_equal 3, captured[:params][2]
  end
end
