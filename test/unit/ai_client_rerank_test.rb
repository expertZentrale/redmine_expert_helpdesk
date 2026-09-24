require File.expand_path('../../test_helper', __FILE__)

# Tests for the AiClient rerank extension (knowledge base / RAG): config and
# fallback resolution, request shape, and reading both common response shapes
# (HTTP stubbed).
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

  # Stub the response and capture the request that went out.
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

  # Matters for existing installations: the key is missing from the settings
  # hash entirely until the form has been saved again.
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

  # TEI returns a bare array instead of a results wrapper.
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

  # A raw-logit deployment would otherwise silently defeat the threshold,
  # which is calibrated on 0..1.
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

  # An index outside the array we sent would otherwise point at the wrong
  # hit.
  def test_out_of_range_indices_are_dropped
    c = client
    stub_post(c, 'results' => [{ 'index' => 5, 'relevance_score' => 0.9 },
                               { 'index' => 0, 'relevance_score' => 0.3 }])
    assert_equal [{ :index => 0, :score => 0.3 }], c.rerank('q', %w[a])
  end

  # kb_rerank_min_score = 0 is explicitly supported, so a score of 0.0 is
  # "accept", not "reject" - a garbage score must therefore drop the row, never
  # coerce to 0.0 and pass an unscored document off as grounding.
  def test_unparseable_scores_are_dropped_not_coerced
    c = client
    stub_post(c, 'results' => [{ 'index' => 0, 'relevance_score' => 'oops' },
                               { 'index' => 1, 'relevance_score' => '0.9garbage' },
                               { 'index' => 2, 'relevance_score' => 0.4 }])
    assert_equal [{ :index => 2, :score => 0.4 }], c.rerank('q', %w[a b c])
  end

  def test_numeric_scores_as_strings_are_still_read
    c = client
    stub_post(c, 'results' => [{ 'index' => 0, 'relevance_score' => '0.75' }])
    assert_in_delta 0.75, c.rerank('q', %w[a]).first[:score], 0.0001
  end

  def test_non_finite_scores_are_dropped
    c = client
    stub_post(c, 'results' => [{ 'index' => 0, 'relevance_score' => 'NaN' },
                               { 'index' => 1, 'relevance_score' => 0.3 }])
    assert_equal [{ :index => 1, :score => 0.3 }], c.rerank('q', %w[a b])
  end

  # to_i would read "abc" as 0 - not a rejected row but a confident pointer at
  # the first hit, which is how a reranker mislabels grounding.
  def test_unparseable_indices_are_dropped_not_coerced
    c = client
    stub_post(c, 'results' => [{ 'index' => 'abc', 'relevance_score' => 0.9 },
                               { 'index' => 1, 'relevance_score' => 0.3 }])
    assert_equal [{ :index => 1, :score => 0.3 }], c.rerank('q', %w[a b])
  end

  # Every row unreadable is indistinguishable from no answer: raise, so
  # retrieval falls back to the vector order rather than to an empty result.
  def test_an_entirely_unreadable_response_raises
    c = client
    stub_post(c, 'results' => [{ 'index' => 'abc', 'relevance_score' => 'oops' }])
    assert_raises(RedmineExpertHelpdesk::AiClient::AiError) { c.rerank('q', %w[a]) }
  end

  def test_carries_its_own_read_timeout
    c = client('kb_rerank_timeout' => '4')
    captured = stub_post(c, 'results' => [{ 'index' => 0, 'relevance_score' => 0.5 }])
    c.rerank('q', %w[a])
    assert_equal 4, captured[:read_timeout]
  end

  # Drives the real post_json with Net::HTTP swapped out, so the timeouts asserted
  # here are the ones production sets.
  class FakeHttp
    attr_accessor :use_ssl, :open_timeout, :read_timeout

    BODY = { 'results' => [{ 'index' => 0, 'relevance_score' => 0.5 }],
             'data' => [{ 'embedding' => [0.1, 0.2] }] }.to_json.freeze

    def request(_req)
      res = Net::HTTPOK.new('1.1', '200', 'OK')
      res.instance_variable_set(:@body, BODY)
      res.instance_variable_set(:@read, true)
      res
    end
  end

  # Swaps Net::HTTP.new for the duration so the real post_json runs and the
  # timeouts asserted are the ones production sets. define_singleton_method
  # rather than minitest/mock - the house idiom in these tests.
  def capture_timeouts(_client)
    fake = FakeHttp.new
    original = Net::HTTP.method(:new)
    Net::HTTP.define_singleton_method(:new) { |*_args| fake }
    begin
      yield
    ensure
      Net::HTTP.define_singleton_method(:new, original)
    end
    { :open => fake.open_timeout, :read => fake.read_timeout }
  end

  # A blackholed host spends its budget connecting, not reading, so leaving the
  # fixed 15 s connect timeout in place would let a 5 s call block for 20 - and
  # the answer draft sizes its lock on these numbers.
  def test_rerank_budget_caps_the_connect_timeout_too
    c = client('kb_rerank_timeout' => '5')
    t = capture_timeouts(c) { c.rerank('q', %w[a]) }
    assert_equal 5, t[:open]
    assert_equal 5, t[:read]
  end

  # The embedding call states no budget of its own, so it inherits ai_timeout -
  # and the connect phase must be bounded by that too, not by the fixed 15 s.
  # The answer draft tightens ai_timeout to EMBED_TIMEOUT and sizes its lock on
  # the result, so an unbounded connect there outlives the lock.
  def test_connect_is_bounded_by_the_inherited_budget_too
    c = client('kb_embed_api_key' => 'sk-embed', 'ai_timeout' => '10')
    t = capture_timeouts(c) { c.embed('hallo') }
    assert_equal 10, t[:open]
    assert_equal 10, t[:read]
  end

  # A generous budget leaves the original connect timeout in force - the cap is
  # a ceiling, not a replacement.
  def test_a_large_budget_keeps_the_default_connect_timeout
    c = client('kb_embed_api_key' => 'sk-embed', 'ai_timeout' => '60')
    t = capture_timeouts(c) { c.embed('hallo') }
    assert_equal RedmineExpertHelpdesk::AiClient::DEFAULT_OPEN_TIMEOUT, t[:open]
    assert_equal 60, t[:read]
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
