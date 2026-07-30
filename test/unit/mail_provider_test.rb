require File.expand_path('../../test_helper', __FILE__)

class MailProviderTest < ActiveSupport::TestCase
  MailProvider = RedmineExpertHelpdesk::MailProvider

  def test_factory_defaults_to_graph
    assert_kind_of RedmineExpertHelpdesk::GraphProvider,
                   MailProvider.for(HelpdeskMailbox.new)
  end

  def test_factory_returns_imap_provider
    mailbox = HelpdeskMailbox.new(:provider => 'imap', :imap_host => 'imap.example.com')
    assert_kind_of RedmineExpertHelpdesk::ImapProvider, MailProvider.for(mailbox)
  end

  # Callers rescue ProviderError; Graph failures have to be caught by it.
  def test_graph_error_is_a_provider_error
    assert RedmineExpertHelpdesk::GraphClient::GraphError < MailProvider::ProviderError
    assert RedmineExpertHelpdesk::GraphClient::ConfigurationError < MailProvider::ProviderError
    assert RedmineExpertHelpdesk::ImapClient::ImapError < MailProvider::ProviderError
    assert RedmineExpertHelpdesk::SmtpSender::SmtpError < MailProvider::ProviderError
  end

  def test_normalize_message_id_strips_brackets
    assert_equal 'abc@example.com',
                 MailProvider.normalize_message_id(' <abc@example.com> ')
    assert_equal '', MailProvider.normalize_message_id(nil)
  end

  def test_message_meta_is_keyword_initialized
    meta = MailProvider::MessageMeta.new(:id => '42', :subject => 'Hi')
    assert_equal '42', meta.id
    assert_equal 'Hi', meta.subject
    assert_nil meta.received_at
  end

  # The Graph adapter must translate the raw JSON payload, so MailProcessor
  # never sees provider-specific keys.
  def test_graph_provider_normalizes_payload
    mailbox = HelpdeskMailbox.new(:mailbox_address => 'hd@example.com', :source_folder => 'Inbox')
    client = FakeGraphClient.new([{
      'id'                => 'AAA',
      'subject'           => 'Betreff',
      'from'              => { 'emailAddress' => { 'address' => 'Kunde@Example.COM', 'name' => 'Kunde' } },
      'receivedDateTime'  => '2026-07-29T10:00:00Z',
      'internetMessageId' => '<xyz@example.com>'
    }])

    meta = RedmineExpertHelpdesk::GraphProvider.new(mailbox, client).list_messages(5).first
    assert_equal 'AAA', meta.id
    assert_equal 'Betreff', meta.subject
    assert_equal 'kunde@example.com', meta.from_address
    assert_equal 'Kunde', meta.from_name
    assert_equal 'xyz@example.com', meta.internet_message_id
    assert_kind_of Time, meta.received_at
  end

  FakeGraphClient = Class.new do
    def initialize(messages)
      @messages = messages
    end

    def configured?
      true
    end

    def list_messages(*)
      @messages
    end
  end
end
