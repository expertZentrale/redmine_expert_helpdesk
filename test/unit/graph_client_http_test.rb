require File.expand_path('../../test_helper', __FILE__)

# Net::HTTP repeats an idempotent request once after a read timeout unless
# max_retries is 0. During an Exchange Online outage that turned every 20 s list
# timeout into 40 s, and a fetch_all run held its web thread twice as long as the
# timeouts promised. Every Graph connection must therefore be built without it.
class GraphClientHttpTest < ActiveSupport::TestCase
  Client = RedmineExpertHelpdesk::GraphClient

  # Records the settings of each connection and answers 200, so the real client
  # code runs end to end without a network.
  class FakeHttp
    attr_accessor :use_ssl, :open_timeout, :read_timeout, :max_retries
    attr_reader :host

    BODY = { 'access_token' => 'token', 'expires_in' => 3600, 'value' => [] }.to_json.freeze

    def initialize(host)
      @host = host
    end

    def request(_req)
      res = Net::HTTPOK.new('1.1', '200', 'OK')
      res.instance_variable_set(:@body, BODY)
      res.instance_variable_set(:@read, true)
      res
    end
  end

  def client
    Client.new('tenant_id' => 'tenant', 'client_id' => 'client', 'client_secret' => 'secret')
  end

  # Swaps Net::HTTP.new for the duration, the house idiom in these tests
  # (see ai_client_rerank_test.rb), and returns every connection built.
  def capture_connections
    built = []
    original = Net::HTTP.method(:new)
    Net::HTTP.define_singleton_method(:new) { |host, *_rest| FakeHttp.new(host).tap { |h| built << h } }
    begin
      yield
    ensure
      Net::HTTP.define_singleton_method(:new, original)
    end
    built
  end

  # The connection to Graph is built before the token is fetched, so pick
  # connections by host, not by position.
  def graph_connections(built)
    built.select { |h| h.host == 'graph.microsoft.com' }
  end

  def assert_no_hidden_retry(built)
    assert built.any?, 'expected the call to open a connection'
    built.each do |http|
      assert_equal 0, http.max_retries, "#{http.host} would repeat a timed-out request"
      assert http.use_ssl
      assert_equal Client::OPEN_TIMEOUT, http.open_timeout
    end
  end

  # The call that hangs in an outage: listing the inbox. The token request runs
  # as well (the test cache stores nothing), so both are covered here.
  def test_listing_messages_does_not_retry_and_keeps_the_short_timeout
    built = capture_connections { client.list_messages('helpdesk@example.com', 'Inbox') }

    assert_equal %w[graph.microsoft.com login.microsoftonline.com], built.map(&:host).sort
    assert_no_hidden_retry(built)
    assert_equal [Client::READ_TIMEOUT, Client::READ_TIMEOUT], built.map(&:read_timeout)
  end

  def test_downloading_a_message_does_not_retry_and_keeps_the_long_timeout
    built = capture_connections { client.message_mime('helpdesk@example.com', 'AAMk') }

    assert_no_hidden_retry(built)
    assert_equal [Client::TRANSFER_TIMEOUT], graph_connections(built).map(&:read_timeout)
  end

  def test_sending_does_not_retry
    built = capture_connections do
      c = client
      c.send_mail('helpdesk@example.com', { 'subject' => 'Hi' })
      c.send_mail_mime('helpdesk@example.com', "Subject: Hi\r\n\r\nBody")
    end

    assert_no_hidden_retry(built)
    assert_equal [Client::TRANSFER_TIMEOUT, Client::TRANSFER_TIMEOUT],
                 graph_connections(built).map(&:read_timeout)
  end
end
