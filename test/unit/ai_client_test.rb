require File.expand_path('../../test_helper', __FILE__)

# Tests fuer den KI-Client: Konfigurationslogik, Endpunkt-Defaults, Provider-
# Dispatch, Payload-Aufbau und Antwort-Parsing (HTTP ueber post_json gestubbt).
class AiClientTest < ActiveSupport::TestCase
  def client(overrides = {})
    settings = {
      'ai_enabled'  => '1', 'ai_provider' => 'openai', 'ai_api_key' => 'sk-test',
      'ai_endpoint' => '',  'ai_model'    => 'gpt-4o-mini',
      'ai_max_output_tokens' => '500', 'ai_timeout' => '60'
    }.merge(overrides)
    RedmineExpertHelpdesk::AiClient.new(settings)
  end

  def test_configured_requires_key_and_model
    assert client.configured?
    assert_not client('ai_api_key' => '').configured?
    assert_not client('ai_model' => '').configured?
  end

  def test_custom_provider_requires_endpoint
    assert_not client('ai_provider' => 'custom', 'ai_endpoint' => '').configured?
    assert client('ai_provider' => 'custom', 'ai_endpoint' => 'https://ai.local/v1').configured?
  end

  def test_endpoint_defaults_per_provider
    assert_equal 'https://api.openai.com/v1', client.endpoint
    assert_equal 'https://api.anthropic.com', client('ai_provider' => 'anthropic').endpoint
    assert_equal 'https://ai.local/v1',
                 client('ai_provider' => 'custom', 'ai_endpoint' => 'https://ai.local/v1').endpoint
  end

  def test_openai_request_shape_and_parse
    c = client
    captured = {}
    c.define_singleton_method(:post_json) do |url, payload, headers|
      captured.merge!(:url => url, :payload => payload, :headers => headers)
      { 'choices' => [{ 'message' => { 'content' => 'Zusammenfassung' } }] }
    end
    assert_equal 'Zusammenfassung', c.summarize('SYS', 'Mailtext')
    assert_equal 'https://api.openai.com/v1/chat/completions', captured[:url]
    assert_equal 'gpt-4o-mini', captured[:payload]['model']
    assert_equal 'SYS',      captured[:payload]['messages'][0]['content']
    assert_equal 'Mailtext', captured[:payload]['messages'][1]['content']
    assert_equal 'Bearer sk-test', captured[:headers]['Authorization']
  end

  def test_anthropic_request_shape_and_parse
    c = client('ai_provider' => 'anthropic', 'ai_model' => 'claude-haiku-4-5')
    captured = {}
    c.define_singleton_method(:post_json) do |url, payload, headers|
      captured.merge!(:url => url, :payload => payload, :headers => headers)
      { 'content' => [{ 'type' => 'text', 'text' => 'Kurz' }] }
    end
    assert_equal 'Kurz', c.summarize('SYS', 'Mailtext')
    assert_equal 'https://api.anthropic.com/v1/messages', captured[:url]
    assert_equal 'SYS',      captured[:payload]['system']
    assert_equal 'Mailtext', captured[:payload]['messages'][0]['content']
    assert_equal 'sk-test',  captured[:headers]['x-api-key']
    assert_equal '2023-06-01', captured[:headers]['anthropic-version']
  end

  def test_custom_provider_uses_openai_shape_at_given_endpoint
    c = client('ai_provider' => 'custom', 'ai_endpoint' => 'https://ai.local/v1')
    captured = {}
    c.define_singleton_method(:post_json) do |url, payload, headers|
      captured.merge!(:url => url)
      { 'choices' => [{ 'message' => { 'content' => 'ok' } }] }
    end
    assert_equal 'ok', c.summarize('s', 'u')
    assert_equal 'https://ai.local/v1/chat/completions', captured[:url]
  end

  def test_openai_vision_content_is_multimodal
    c = client
    captured = {}
    c.define_singleton_method(:post_json) do |_url, payload, _headers|
      captured[:payload] = payload
      { 'choices' => [{ 'message' => { 'content' => 'x' } }] }
    end
    c.summarize('SYS', 'txt', [{ :content_type => 'image/png', :data => 'BASE64' }])
    content = captured[:payload]['messages'][1]['content']
    assert content.is_a?(Array)
    assert_equal 'text', content[0]['type']
    assert_equal 'image_url', content[1]['type']
    assert_match %r{\Adata:image/png;base64,BASE64}, content[1]['image_url']['url']
  end

  def test_openai_uses_max_completion_tokens
    c = client
    captured = {}
    c.define_singleton_method(:post_json) do |_url, payload, _headers|
      captured[:payload] = payload
      { 'choices' => [{ 'message' => { 'content' => 'x' } }] }
    end
    c.summarize('s', 'u')
    assert captured[:payload].key?('max_completion_tokens'), 'OpenAI must use max_completion_tokens (GPT-5/o-series reject max_tokens)'
    assert_not captured[:payload].key?('max_tokens')
  end

  def test_custom_provider_uses_max_tokens
    c = client('ai_provider' => 'custom', 'ai_endpoint' => 'https://ai.local/v1')
    captured = {}
    c.define_singleton_method(:post_json) do |_url, payload, _headers|
      captured[:payload] = payload
      { 'choices' => [{ 'message' => { 'content' => 'x' } }] }
    end
    c.summarize('s', 'u')
    assert captured[:payload].key?('max_tokens'), 'Self-hosted OpenAI-compatible servers expect max_tokens'
    assert_not captured[:payload].key?('max_completion_tokens')
  end

  def test_openai_captures_token_usage
    c = client
    c.define_singleton_method(:post_json) do |*|
      { 'choices' => [{ 'message' => { 'content' => 'x' } }],
        'usage' => { 'prompt_tokens' => 120, 'completion_tokens' => 45 } }
    end
    c.summarize('s', 'u')
    assert_equal 120, c.last_usage[:input]
    assert_equal 45,  c.last_usage[:output]
  end

  def test_anthropic_captures_token_usage
    c = client('ai_provider' => 'anthropic', 'ai_model' => 'claude-haiku-4-5')
    c.define_singleton_method(:post_json) do |*|
      { 'content' => [{ 'type' => 'text', 'text' => 'x' }],
        'usage' => { 'input_tokens' => 80, 'output_tokens' => 20 } }
    end
    c.summarize('s', 'u')
    assert_equal 80, c.last_usage[:input]
    assert_equal 20, c.last_usage[:output]
  end

  def test_usage_is_blank_when_provider_omits_it
    c = client
    c.define_singleton_method(:post_json) { |*| { 'choices' => [{ 'message' => { 'content' => 'x' } }] } }
    c.summarize('s', 'u')
    assert_nil c.last_usage[:input]
    assert_nil c.last_usage[:output]
  end

  def test_summarize_raises_when_not_configured
    assert_raises(RedmineExpertHelpdesk::AiClient::ConfigurationError) do
      client('ai_api_key' => '').summarize('s', 'u')
    end
  end

  def test_blank_response_raises
    c = client
    c.define_singleton_method(:post_json) { |*| { 'choices' => [{ 'message' => { 'content' => '' } }] } }
    assert_raises(RedmineExpertHelpdesk::AiClient::AiError) { c.summarize('s', 'u') }
  end
end
