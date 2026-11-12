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

  # What FetchAll reads from and writes to a mailbox.
  FakeMailbox = Struct.new(:mailbox_address, :provider, :imap_host, :project, :id,
                           :last_fetched_at, :last_error_at, :last_error) do
    def imap?
      provider == 'imap'
    end

    def update_columns(attributes)
      attributes.each { |name, value| self[name] = value }
      true
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

  # Never attempted, ids in creation order: in_turn keeps the order they are
  # created in.
  def mailbox(address, provider = 'graph', host = nil, last_attempt: nil)
    @next_id = (@next_id || 0) + 1
    FakeMailbox.new(address, provider, host, @project, @next_id, last_attempt)
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

  # Near LOCK_TTL the entry may expire and be taken by the next run at any
  # moment; deleting it then could free that run's lock for a third. Such a run
  # leaves the lock to expire.
  def test_a_run_that_came_close_to_the_ttl_leaves_the_lock_to_expire
    FetchAll.any_instance.stubs(:run).returns({})
    FetchAll.stubs(:clock).returns(0, FetchAll::LOCK_TTL.to_i - FetchAll::RELEASE_MARGIN)

    FetchAll.run([])
    assert Rails.cache.exist?(FetchAll::LOCK_KEY)
  end

  def test_a_normal_run_releases_the_lock
    FetchAll.any_instance.stubs(:run).returns({})
    FetchAll.stubs(:clock).returns(0, 5)

    FetchAll.run([])
    assert_not Rails.cache.exist?(FetchAll::LOCK_KEY)
  end

  # --- no second try against a service that is down -------------------------

  def test_three_failures_in_a_row_defer_the_rest_of_that_service_but_not_other_services
    g1, g2, g3, g4 = %w[g1 g2 g3 g4].map { |name| mailbox("#{name}@example.com") }
    i1 = mailbox('i1@example.com', 'imap', 'mail.example.com')
    processors(g1 => FakeProcessor.new(:unavailable => true), g2 => FakeProcessor.new(:unavailable => true),
               g3 => FakeProcessor.new(:unavailable => true), i1 => FakeProcessor.new)
    MailProcessor.expects(:new).with(g4).never

    summary = FetchAll.new([g1, g2, g3, g4, i1]).run
    %w[g1 g2 g3].each { |name| assert summary["#{name}@example.com"].key?(:processed) }
    assert_equal({ :deferred => 'service_unavailable' }, summary['g4@example.com'])
    assert summary['i1@example.com'].key?(:processed), 'an IMAP server is a service of its own'
  end

  # An Exchange outage often hits only some mailboxes, and a single broken one
  # must not hold back the rest: a success in between starts the count again.
  def test_a_success_in_between_resets_the_count
    boxes = %w[g1 g2 g3 g4 g5].map { |name| mailbox("#{name}@example.com") }
    unavailable = [true, false, true, true, false]
    processors(boxes.zip(unavailable.map { |flag| FakeProcessor.new(:unavailable => flag) }).to_h)

    summary = FetchAll.new(boxes).run
    assert(summary.values.none? { |result| result.key?(:deferred) }, summary.inspect)
  end

  # IMAP wraps the whole session in Timeout, which raises out of process_all.
  def test_a_timeout_raised_out_of_the_fetch_counts_as_unavailable
    i1, i2, i3, i4 = %w[i1 i2 i3 i4].map { |name| mailbox("#{name}@example.com", 'imap', 'mail.example.com') }
    i4.imap_host = 'MAIL.example.com'
    other = mailbox('o1@example.com', 'imap', 'other.example.com')
    timeout = Timeout::Error.new('execution expired')
    processors(i1 => FakeProcessor.new(:raises => timeout), i2 => FakeProcessor.new(:raises => timeout),
               i3 => FakeProcessor.new(:raises => timeout), other => FakeProcessor.new)
    MailProcessor.expects(:new).with(i4).never

    summary = FetchAll.new([i1, i2, i3, i4, other]).run
    assert_equal({ :error => 'execution expired' }, summary['i1@example.com'])
    assert_equal({ :deferred => 'service_unavailable' }, summary['i4@example.com'], 'host compared case-insensitively')
    assert summary['o1@example.com'].key?(:processed)
  end

  # process_all records its outcome itself; an error raised out of it is
  # recorded here, or the mailbox would look untried and stay first in line.
  def test_an_error_raised_out_of_the_fetch_is_recorded_on_the_mailbox
    box = mailbox('i1@example.com', 'imap', 'mail.example.com')
    processors(box => FakeProcessor.new(:raises => Timeout::Error.new('execution expired')))

    FetchAll.new([box]).run
    assert_not_nil box.last_error_at
    assert_includes box.last_error, 'execution expired'
  end

  # --- taking turns ----------------------------------------------------------

  def test_mailboxes_take_turns_longest_since_the_last_attempt_first
    recent    = mailbox('recent@example.com', :last_attempt => 1.minute.ago)
    never     = mailbox('never@example.com')
    long_ago  = mailbox('long-ago@example.com', :last_attempt => 2.hours.ago)
    errored   = mailbox('errored@example.com')
    errored.last_error_at = 30.minutes.ago

    assert_equal %w[never long-ago errored recent],
                 FetchAll.in_turn([recent, never, long_ago, errored]).map { |box| box.mailbox_address.split('@').first }
  end

  # The newer of the two timestamps counts: a mailbox that just failed goes to
  # the back even if its last success is old.
  def test_a_mailbox_that_just_failed_goes_to_the_back
    failing = mailbox('failing@example.com', :last_attempt => 3.hours.ago)
    failing.last_error_at = Time.current
    other = mailbox('other@example.com', :last_attempt => 1.hour.ago)

    assert_equal [other, failing], FetchAll.in_turn([failing, other])
  end

  def test_the_run_fetches_in_turn
    late  = mailbox('late@example.com', :last_attempt => 1.minute.ago)
    early = mailbox('early@example.com', :last_attempt => 1.hour.ago)
    fetched = []
    processors(late => FakeProcessor.new { fetched << 'late' }, early => FakeProcessor.new { fetched << 'early' })

    FetchAll.new([late, early]).run
    assert_equal %w[early late], fetched
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
    FetchAll.stubs(:clock).returns(0, 1000)

    processor.process_all(25, :deadline => 500)
    assert_equal %w[m1], handled
  end

  # A slow listing can use up the budget on its own; then not even the first
  # message is started.
  def test_processor_starts_no_message_when_listing_used_up_the_budget
    processor = processor_with(ListingProvider.new)
    handled = []
    processor.define_singleton_method(:process_message) { |meta, _result| handled << meta.id }
    FetchAll.stubs(:clock).returns(1000)

    processor.process_all(25, :deadline => 500)
    assert_empty handled
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

  # The service failed before MailHandler saw the mail (here: downloading the
  # MIME): nothing was stored, so it stays unread for the next fetch instead of
  # ending up in the error folder.
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

  # After the hand-off a ticket or note may exist. Left unread, the mail would
  # be ingested a second time on the next fetch - it is filed as failed instead,
  # and the cycle still stops.
  def test_processor_files_a_message_as_failed_when_the_service_fails_after_the_hand_off
    provider = ListingProvider.new
    processor = processor_with(provider, :failed_folder => 'Fehler')
    handled = []
    processor.define_singleton_method(:process_message) do |meta, _result|
      handled << meta.id
      @handed_to_mail_handler = true
      raise Net::ReadTimeout
    end

    processor.process_all
    assert_equal %w[m1], handled
    assert_includes provider.calls, [:mark_as_read, 'm1']
    assert_includes provider.calls, [:move_message, 'm1', 'Fehler']
    assert processor.service_unavailable?
  end

  # A broken message, but the service fails on the move to the error folder:
  # the cycle stops instead of trying the next message against it.
  def test_processor_stops_when_the_move_to_the_error_folder_times_out
    provider = ListingProvider.new
    provider.define_singleton_method(:mark_as_read) { |_id| raise Net::ReadTimeout }
    processor = processor_with(provider, :failed_folder => 'Fehler')
    handled = []
    processor.define_singleton_method(:process_message) do |meta, _result|
      handled << meta.id
      raise 'broken MIME'
    end

    processor.process_all
    assert_equal %w[m1], handled
    assert processor.service_unavailable?
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
     MailProvider::AuthenticationError.new('bad credentials'), RuntimeError.new('bug'),
     Errno::ENOSPC.new, Errno::EACCES.new, IOError.new('closed stream')].each do |error|
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
