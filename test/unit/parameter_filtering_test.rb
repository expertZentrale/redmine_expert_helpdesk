require File.expand_path('../../test_helper', __FILE__)

# The plugin stores several API keys, and they are posted through ordinary
# settings forms. Redmine's own filter list covers :password and :secret, which
# catches client_secret but left every *_api_key in the request log in clear
# text - including the AI provider key, on an endpoint an admin saves regularly.
class ParameterFilteringTest < ActiveSupport::TestCase
  def filtered(params)
    ActiveSupport::ParameterFilter.new(Rails.application.config.filter_parameters).filter(params)
  end

  def test_plugin_api_keys_are_filtered_from_the_log
    result = filtered('settings' => {
      'ai_api_key'        => 'sk-secret-chat',
      'kb_embed_api_key'  => 'sk-secret-embed',
      'kb_qdrant_api_key' => 'qdrant-secret',
      'fetch_api_key'     => 'fetch-secret',
      'sla_api_key'       => 'sla-secret',
      'phishtank_app_key' => 'phish-secret'
    })

    result['settings'].each do |name, value|
      assert_equal '[FILTERED]', value, "#{name} reached the log in clear text"
    end
  end

  # Registered by the plugin itself rather than inherited: the host's filter list
  # differs across the supported Redmine versions, and on 5.1/6.0 client_secret
  # is not covered by it at all - which CI caught when this test relied on it.
  def test_client_secret_and_mailbox_passwords_are_filtered
    result = filtered('settings' => { 'client_secret' => 'azure-secret' },
                      'helpdesk_mailbox' => { 'imap_password' => 'mailbox-secret',
                                              'smtp_password' => 'mailbox-secret' })
    assert_equal '[FILTERED]', result['settings']['client_secret']
    assert_equal '[FILTERED]', result['helpdesk_mailbox']['imap_password']
    assert_equal '[FILTERED]', result['helpdesk_mailbox']['smtp_password']
  end

  # The filter matches substrings, so an over-broad ":key" would also hide
  # settings that are not secrets at all.
  def test_ordinary_settings_are_not_filtered
    result = filtered('settings' => {
      'info_request_keywords' => 'Drucker, Kasse',
      'kb_qdrant_url'         => 'http://qdrant:6333',
      'ai_model'              => 'Qwen3.6-35B-A3B',
      'ai_answer_min_score'   => '0.65'
    })

    assert_equal 'Drucker, Kasse',        result['settings']['info_request_keywords']
    assert_equal 'http://qdrant:6333',    result['settings']['kb_qdrant_url']
    assert_equal 'Qwen3.6-35B-A3B',       result['settings']['ai_model']
    assert_equal '0.65',                  result['settings']['ai_answer_min_score']
  end
end
