require File.expand_path('../../test_helper', __FILE__)

# Tests fuer die Embeddings-Erweiterung des AiClient (Wissensbasis/RAG):
# Konfigurations-/Fallback-Aufloesung und Request/Parse (HTTP gestubbt).
class AiClientEmbedTest < ActiveSupport::TestCase
  def client(overrides = {})
    settings = {
      'ai_provider' => 'openai', 'ai_api_key' => 'sk-chat', 'ai_endpoint' => '', 'ai_model' => 'gpt-4o-mini',
      'kb_embed_provider' => 'openai', 'kb_embed_model' => 'text-embedding-3-small',
      'kb_embed_endpoint' => '', 'kb_embed_api_key' => ''
    }.merge(overrides)
    RedmineExpertHelpdesk::AiClient.new(settings)
  end

  def test_embed_configured_with_own_key
    assert client('kb_embed_api_key' => 'sk-embed').embed_configured?
  end

  def test_embed_key_falls_back_to_chat_when_same_provider
    c = client('kb_embed_api_key' => '')
    assert_equal 'sk-chat', c.embed_api_key
    assert c.embed_configured?
  end

  def test_embed_key_not_shared_across_providers
    c = client('kb_embed_provider' => 'custom', 'kb_embed_api_key' => '')
    assert_equal '', c.embed_api_key
  end

  def test_embed_endpoint_default_openai
    assert_equal 'https://api.openai.com/v1', client.embed_endpoint
  end

  def test_embed_request_shape_and_parse
    c = client('kb_embed_api_key' => 'sk-embed')
    captured = {}
    c.define_singleton_method(:post_json) do |url, payload, headers|
      captured.merge!(:url => url, :payload => payload, :headers => headers)
      { 'data' => [{ 'embedding' => [0.1, 0.2, 0.3] }] }
    end
    assert_equal [0.1, 0.2, 0.3], c.embed('hallo')
    assert_equal 'https://api.openai.com/v1/embeddings', captured[:url]
    assert_equal 'text-embedding-3-small', captured[:payload]['model']
    assert_equal 'hallo', captured[:payload]['input']
    assert_equal 'Bearer sk-embed', captured[:headers]['Authorization']
  end

  def test_embed_raises_when_not_configured
    assert_raises(RedmineExpertHelpdesk::AiClient::ConfigurationError) do
      client('kb_embed_provider' => 'custom', 'kb_embed_endpoint' => '', 'kb_embed_api_key' => '').embed('x')
    end
  end
end
