require File.expand_path('../../test_helper', __FILE__)

# Tests fuer die Rerank-Erweiterung des AiClient (Wissensbasis/RAG):
# Konfigurations-/Fallback-Aufloesung, Request-Form, und das Lesen beider
# verbreiteten Antwortformen (HTTP gestubbt).
class AiClientRerankTest < ActiveSupport::TestCase
  def client(overrides = {})
    settings = {
      'ai_provider' => 'openai', 'ai_api_key' => 'sk-chat', 'ai_endpoint' => '', 'ai_model' => 'gpt-4o-mini',
      'kb_embed_provider' => 'custom', 'kb_embed_model' => 'bge-m3',
      'kb_embed_endpoint' => 'https://api.ai.net.de/v1', 'kb_embed_api_key' => 'sk-embed',
      'kb_rerank_enabled' => '1'
    }.merge(overrides)
    RedmineExpertHelpdesk::AiClient.new(settings)
  end

  # Antwort stubben und den abgesetzten Request einsammeln.
  def stub_post(c, response)
    captured = {}
    c.define_singleton_method(:post_json) do |url, payload, headers = {}, read_timeout: nil|
      captured.merge!(:url => url, :payload => payload, :headers => headers, :read_timeout => read_timeout)
      response
    end
    captured
  end

  def test_disabled_by_default
    assert_not client('kb_rerank_enabled' => '0').rerank_configured?
  end

  def test_model_falls_back_to_the_shipped_default
    assert_equal 'bge-reranker-v2-m3', client('kb_rerank_model' => '').rerank_model
  end

  # Wichtig fuer bestehende Installationen: der Schluessel fehlt im
  # Einstellungs-Hash komplett, bis das Formular neu gespeichert wurde.
  def test_defaults_apply_when_the_setting_key_is_absent
    c = client
    assert_equal 'bge-reranker-v2-m3', c.rerank_model
    assert_equal RedmineExpertHelpdesk::AiClient::DEFAULT_RERANK_TIMEOUT, c.rerank_timeout
  end

  def test_endpoint_and_key_fall_back_to_the_embeddings_config
    c = client
    assert_equal 'https://api.ai.net.de/v1', c.rerank_endpoint
    assert_equal 'sk-embed', c.rerank_api_key
    assert c.rerank_configured?
  end

  def test_own_endpoint_and_key_win
    c = client('kb_rerank_endpoint' => 'https://rerank.example.com/v1/', 'kb_rerank_api_key' => 'sk-rr')
    assert_equal 'https://rerank.example.com/v1', c.rerank_endpoint
    assert_equal 'sk-rr', c.rerank_api_key
  end

  def test_request_shape_and_jina_response
    c = client
    captured = stub_post(c, 'results' => [{ 'index' => 1, 'relevance_score' => 0.9 },
                                          { 'index' => 0, 'relevance_score' => 0.2 }])
    rows = c.rerank('drucker', %w[aaa bbb])

    assert_equal 'https://api.ai.net.de/v1/rerank', captured[:url]
    assert_equal 'bge-reranker-v2-m3', captured[:payload]['model']
    assert_equal 'drucker', captured[:payload]['query']
    assert_equal %w[aaa bbb], captured[:payload]['documents']
    assert_equal 'Bearer sk-embed', captured[:headers]['Authorization']
    assert_equal [{ :index => 1, :score => 0.9 }, { :index => 0, :score => 0.2 }], rows
  end

  # TEI liefert ein nacktes Array statt eines results-Wrappers.
  def test_bare_array_response_is_read
    c = client
    stub_post(c, [{ 'index' => 0, 'score' => 0.4 }, { 'index' => 1, 'score' => 0.8 }])
    assert_equal [{ :index => 1, :score => 0.8 }, { :index => 0, :score => 0.4 }], c.rerank('q', %w[a b])
  end

  def test_results_are_sorted_by_score_descending
    c = client
    stub_post(c, 'results' => [{ 'index' => 0, 'relevance_score' => 0.1 },
                               { 'index' => 2, 'relevance_score' => 0.7 },
                               { 'index' => 1, 'relevance_score' => 0.4 }])
    assert_equal [2, 1, 0], c.rerank('q', %w[a b c]).map { |r| r[:index] }
  end

  # Eine Roh-Logit-Installation wuerde den auf 0..1 geeichten Schwellwert
  # sonst still aushebeln.
  def test_raw_logits_are_squashed_into_zero_to_one
    c = client
    stub_post(c, 'results' => [{ 'index' => 0, 'relevance_score' => 6.0 },
                               { 'index' => 1, 'relevance_score' => -6.0 }])
    rows = c.rerank('q', %w[a b])
    assert rows.all? { |r| r[:score].between?(0.0, 1.0) }, rows.inspect
    assert rows.first[:score] > 0.99
    assert rows.last[:score] < 0.01
  end

  def test_scores_already_in_range_are_left_alone
    c = client
    stub_post(c, 'results' => [{ 'index' => 0, 'relevance_score' => 0.42 }])
    assert_in_delta 0.42, c.rerank('q', %w[a]).first[:score], 0.0001
  end

  # Ein Index ausserhalb des gesendeten Arrays wuerde sonst auf den falschen
  # Treffer zeigen.
  def test_out_of_range_indices_are_dropped
    c = client
    stub_post(c, 'results' => [{ 'index' => 5, 'relevance_score' => 0.9 },
                               { 'index' => 0, 'relevance_score' => 0.3 }])
    assert_equal [{ :index => 0, :score => 0.3 }], c.rerank('q', %w[a])
  end

  def test_carries_its_own_read_timeout
    c = client('kb_rerank_timeout' => '4')
    captured = stub_post(c, 'results' => [{ 'index' => 0, 'relevance_score' => 0.5 }])
    c.rerank('q', %w[a])
    assert_equal 4, captured[:read_timeout]
  end

  def test_empty_document_list_short_circuits
    c = client
    c.define_singleton_method(:post_json) { |*| raise 'must not be called' }
    assert_equal [], c.rerank('q', [])
  end

  def test_unreadable_response_raises
    c = client
    stub_post(c, 'results' => [])
    assert_raises(RedmineExpertHelpdesk::AiClient::AiError) { c.rerank('q', %w[a]) }
  end

  def test_raises_when_not_configured
    assert_raises(RedmineExpertHelpdesk::AiClient::ConfigurationError) do
      client('kb_rerank_enabled' => '0').rerank('q', %w[a])
    end
  end
end
