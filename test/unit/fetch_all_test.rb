require File.expand_path('../../test_helper', __FILE__)

# The cron fetch runs inside a web request. In the Exchange Online outage of
# 2026-11-12 every Graph call hung for 30 s, one fetch_all took minutes, proxy
# retries stacked them up and they held every web thread - Redmine was down for
# everybody. These tests pin the guards: one run at a time, a time budget, and
# no second try against a service that just timed out.
class FetchAllTest < ActiveSupport::TestCase
  FetchAll      = RedmineExpertHelpdesk::FetchAll
  MailProcessor = RedmineExpertHelpdesk::MailProcessor
  MailProvider  = RedmineExpertHelpdesk::MailProvider
  GraphError    = RedmineExpertHelpdesk::GraphClient::GraphError

  Meta = Struct.new(:id, :subject)

  # What FetchAll reads from a mailbox.
  FakeMailbox = Struct.new(:mailbox_address, :provider, :imap_host, :project) do
    def imap?
      provider == 'imap'
    end
  end

  # Stands in for MailProcessor: returns an empty result or raises, and reports
  # an unavailable service when told to.
  class FakeProcessor
    def initialize(unavailable: false, raises: nil, &on_run)
      @unavailable = unavailable
      @raises = raises
      @on_run = on_run
    end

    def process_all(_limit, deadline: nil)
      @on_run&.call
      raise @raises if @raises

      MailProcessor::Result.new(0, [], [], 0, [])
    end

    def service_unavailable?
      @unavailable
    end
  end

  # Lists three messages (or fails to); records the moves.
  class ListingProvider
    attr_reader :calls

    def initialize(list_error = nil)
      @list_error = list_error
      @calls = []
    end

    def with_session
      yield
    end

    def list_messages(_limit)
      raise @list_error if @list_error

      [Meta.new('m1', 'one'), Meta.new('m2', 'two'), Meta.new('m3', 'three')]
    end

    def mark_as_read(id)
      @calls << [:mark_as_read, id]
    end

    def move_message(id, folder)
      @calls << [:move_message, id, folder]
    end
  end

  # Redmine's test environment runs a null cache store, under which every lock
  # write succeeds; the lock needs a store that stores.
  def setup
    @previous_cache = Rails.cache
    Rails.cache = ActiveSupport::Cache::MemoryStore.new
    HelpdeskFetchRun.delete_all
    @project = stub(:active? => true, :module_enabled? => true)
    RedmineExpertHelpdesk::PhishingFeeds.stubs(:due?).returns(false)
  end

  def teardown
    Rails.cache = @previous_cache
  end

  def mailbox(address, provider = 'graph', host = nil)
    FakeMailbox.new(address, provider, host, @project)
  end

  def processors(map)
    map.each { |box, processor| MailProcessor.stubs(:new).with(box).returns(processor) }
  end

  def processor_with(provider, attrs = {})
    box = HelpdeskMailbox.new({ :mailbox_address => 'support@example.com' }.merge(attrs))
    box.stubs(:update_columns) # last_fetched_at / last_error; the mailbox is not persisted
    MailProcessor.new(box, provider)
  end

  # --- one run at a time ---------------------------------------------------

  def test_a_second_run_returns_at_once_while_the_first_holds_the_lock
    Rails.cache.write(FetchAll::LOCK_KEY, 'other run')
    MailProcessor.expects(:new).never

    assert_nil FetchAll.run([mailbox('a@example.com')])
    assert_equal 'other run', Rails.cache.read(FetchAll::LOCK_KEY), 'the other run keeps its lock'
  end

  def test_the_lock_is_released_after_the_run_even_when_it_raises
    box = mailbox('a@example.com')
    processors(box => FakeProcessor.new)

    summary = FetchAll.run([box])
    assert summary['a@example.com'].key?(:processed)
    assert_nil Rails.cache.read(FetchAll::LOCK_KEY)

    FetchAll.any_instance.stubs(:run).raises(RuntimeError, 'boom')
    assert_raises(RuntimeError) { FetchAll.run([box]) }
    assert_nil Rails.cache.read(FetchAll::LOCK_KEY)
  end

  # After LOCK_TTL another run may have taken the lock; finishing late must not
  # free it for a third.
  def test_a_lock_taken_over_meanwhile_is_left_alone
    box = mailbox('a@example.com')
    processors(box => FakeProcessor.new { Rails.cache.write(FetchAll::LOCK_KEY, 'next run') })

    FetchAll.run([box])
    assert_equal 'next run', Rails.cache.read(FetchAll::LOCK_KEY)
  end

  # --- no second try against a service that is down -------------------------

  def test_an_unavailable_service_defers_its_other_mailboxes_but_not_other_services
    g1 = mailbox('g1@example.com')
    g2 = mailbox('g2@example.com')
    i1 = mailbox('i1@example.com', 'imap', 'mail.example.com')
    processors(g1 => FakeProcessor.new(:unavailable => true), i1 => FakeProcessor.new)
    MailProcessor.expects(:new).with(g2).never

    summary = FetchAll.new([g1, g2, i1]).run
    assert summary['g1@example.com'].key?(:processed)
    assert_equal({ :deferred => 'service_unavailable' }, summary['g2@example.com'])
    assert summary['i1@example.com'].key?(:processed), 'an IMAP server is a service of its own'
  end

  # IMAP wraps the whole session in Timeout, which raises out of process_all.
  def test_a_timeout_raised_out_of_the_fetch_counts_as_unavailable
    i1 = mailbox('i1@example.com', 'imap', 'mail.example.com')
    i2 = mailbox('i2@example.com', 'imap', 'MAIL.example.com')
    i3 = mailbox('i3@example.com', 'imap', 'other.example.com')
    processors(i1 => FakeProcessor.new(:raises => Timeout::Error.new('execution expired')),
               i3 => FakeProcessor.new)
    MailProcessor.expects(:new).with(i2).never

    summary = FetchAll.new([i1, i2, i3]).run
    assert_equal({ :error => 'execution expired' }, summary['i1@example.com'])
    assert_equal({ :deferred => 'service_unavailable' }, summary['i2@example.com'], 'host compared case-insensitively')
    assert summary['i3@example.com'].key?(:processed)
  end

  def test_an_error_of_one_mailbox_does_not_stop_the_others
    g1 = mailbox('g1@example.com')
    g2 = mailbox('g2@example.com')
    processors(g1 => FakeProcessor.new(:raises => GraphError.new('access denied', 403)), g2 => FakeProcessor.new)

    summary = FetchAll.new([g1, g2]).run
    assert_equal({ :error => 'access denied' }, summary['g1@example.com'])
    assert summary['g2@example.com'].key?(:processed)
  end

  def test_mailboxes_of_inactive_projects_are_left_out
    box = FakeMailbox.new('a@example.com', 'graph', nil, stub(:active? => false))
    MailProcessor.expects(:new).never

    assert_equal({}, FetchAll.new([box]).run)
  end

  # --- time budget -----------------------------------------------------------

  def test_no_mailbox_is_started_once_the_budget_is_used_up
    a = mailbox('a@example.com')
    b = mailbox('b@example.com')
    processors(a => FakeProcessor.new)
    MailProcessor.expects(:new).with(b).never
    HelpdeskPhishingFeedsJob.expects(:perform_later).never
    # deadline = 0 + 100; a starts at 0, b would start at 100
    FetchAll.stubs(:clock).returns(0, 0, 100)

    summary = FetchAll.new([a, b], 100).run
    assert summary['a@example.com'].key?(:processed)
    assert_equal({ :deferred => 'time_budget' }, summary['b@example.com'])
  end

  # A due sync took minutes inline; it is queued instead.
  def test_due_phishing_feeds_are_queued_not_run_in_the_request
    RedmineExpertHelpdesk::PhishingFeeds.stubs(:due?).returns(true)
    RedmineExpertHelpdesk::PhishingFeeds.expects(:run_if_stale).never
    HelpdeskPhishingFeedsJob.expects(:perform_later).once
    FetchAll.new([]).run
  end

  def test_nothing_is_queued_when_no_feed_is_due
    HelpdeskPhishingFeedsJob.expects(:perform_later).never
    FetchAll.new([]).run
  end

  def test_the_job_runs_the_due_feeds
    RedmineExpertHelpdesk::PhishingFeeds.expects(:run_if_stale).once.returns(true)
    HelpdeskPhishingFeedsJob.perform_now
  end

  # --- MailProcessor ---------------------------------------------------------

  def test_processor_starts_no_message_after_the_deadline
    processor = processor_with(ListingProvider.new)
    handled = []
    processor.define_singleton_method(:process_message) { |meta, _result| handled << meta.id }
    FetchAll.stubs(:clock).returns(1000)

    processor.process_all(25, :deadline => 500)
    assert_equal %w[m1], handled, 'the first message is always handled, then the run stops'
  end

  def test_processor_without_deadline_handles_every_message
    processor = processor_with(ListingProvider.new)
    handled = []
    processor.define_singleton_method(:process_message) { |meta, _result| handled << meta.id }

    processor.process_all
    assert_equal %w[m1 m2 m3], handled
  end

  def test_processor_reports_an_unavailable_service_when_listing_times_out
    processor = processor_with(ListingProvider.new(Net::ReadTimeout.new))

    result = processor.process_all
    assert processor.service_unavailable?
    assert_equal 1, result.errors.size
  end

  def test_processor_does_not_take_a_refused_mailbox_for_an_outage
    processor = processor_with(ListingProvider.new(GraphError.new('access denied', 403)))

    processor.process_all
    assert_not processor.service_unavailable?
  end

  # The service failed, not the message: it must stay unread in the source
  # folder for the next fetch, not end up in the error folder.
  def test_processor_leaves_a_message_in_place_and_stops_when_the_service_times_out
    provider = ListingProvider.new
    processor = processor_with(provider, :failed_folder => 'Fehler')
    handled = []
    processor.define_singleton_method(:process_message) do |meta, _result|
      handled << meta.id
      raise Net::ReadTimeout
    end

    result = processor.process_all
    assert_equal %w[m1], handled
    assert_empty provider.calls, 'neither marked read nor moved'
    assert processor.service_unavailable?
    assert_equal 1, result.errors.size
  end

  def test_processor_still_files_a_broken_message_as_failed
    provider = ListingProvider.new
    processor = processor_with(provider, :failed_folder => 'Fehler')
    processor.define_singleton_method(:process_message) do |meta, _result|
      raise 'broken MIME' if meta.id == 'm1'
    end

    processor.process_all
    assert_includes provider.calls, [:move_message, 'm1', 'Fehler']
    assert_not processor.service_unavailable?
  end

  # --- MailProvider.service_unavailable? -------------------------------------

  def test_timeouts_connection_failures_5xx_and_429_count_as_unavailable
    [Net::ReadTimeout.new, Net::OpenTimeout.new, Timeout::Error.new, Errno::ECONNREFUSED.new,
     SocketError.new('getaddrinfo'), EOFError.new, GraphError.new('gateway timeout', 504),
     GraphError.new('bad gateway', 502), GraphError.new('throttled', 429)].each do |error|
      assert MailProvider.service_unavailable?(error), "#{error.class}: #{error.message}"
    end
  end

  def test_mailbox_problems_do_not_count_as_unavailable
    [GraphError.new('access denied', 403), GraphError.new('folder not found'),
     MailProvider::AuthenticationError.new('bad credentials'), RuntimeError.new('bug')].each do |error|
      assert_not MailProvider.service_unavailable?(error), "#{error.class}: #{error.message}"
    end
  end

  def test_a_wrapped_socket_error_counts_as_unavailable
    wrapped = begin
      begin
        raise Errno::ECONNRESET
      rescue Errno::ECONNRESET
        raise RedmineExpertHelpdesk::ImapClient::ImapError, 'IMAP mail.example.com:993: Connection reset'
      end
    rescue RedmineExpertHelpdesk::ImapClient::ImapError => e
      e
    end

    assert MailProvider.service_unavailable?(wrapped)
  end
end
