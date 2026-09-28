require File.expand_path('../../test_helper', __FILE__)

# Maintenance mode: the fetch loop honours the flag, and every fetch is visible
# as a HelpdeskFetchRun while it runs.
class HelpdeskMaintenanceTest < ActiveSupport::TestCase
  Meta = Struct.new(:id, :subject)

  # Records what the processor asked for; list_messages hands out two messages.
  class FakeProvider
    attr_reader :listed

    def with_session
      yield
    end

    def list_messages(_limit)
      @listed = true
      [Meta.new('m1', 'first'), Meta.new('m2', 'second')]
    end
  end

  def setup
    HelpdeskFetchRun.delete_all
    @saved = Setting.plugin_redmine_expert_helpdesk
    @mailbox = HelpdeskMailbox.new(:mailbox_address => 'support@example.com')
  end

  def teardown
    Setting.plugin_redmine_expert_helpdesk = @saved
  end

  def processor(provider)
    RedmineExpertHelpdesk::MailProcessor.new(@mailbox, provider)
  end

  def test_set_and_active_round_trip
    RedmineExpertHelpdesk::Maintenance.set!(true)
    assert RedmineExpertHelpdesk::Maintenance.active?
    assert RedmineExpertHelpdesk::Maintenance.active?(:fresh => true)
    RedmineExpertHelpdesk::Maintenance.set!(false)
    assert_not RedmineExpertHelpdesk::Maintenance.active?(:fresh => true)
  end

  def test_set_keeps_the_other_settings
    Setting.plugin_redmine_expert_helpdesk = @saved.to_h.merge('fetch_api_key' => 'k3y')
    RedmineExpertHelpdesk::Maintenance.set!(true)
    assert_equal 'k3y', Setting.plugin_redmine_expert_helpdesk['fetch_api_key']
  end

  def test_process_all_fetches_nothing_in_maintenance
    RedmineExpertHelpdesk::Maintenance.set!(true)
    provider = FakeProvider.new
    result = processor(provider).process_all
    assert_nil provider.listed
    assert_equal 0, result.processed
    assert_equal 0, HelpdeskFetchRun.count, 'run row removed afterwards'
  end

  def test_switching_on_mid_cycle_stops_before_the_next_message
    RedmineExpertHelpdesk::Maintenance.set!(false)
    @mailbox.stubs(:update_columns) # last_fetched_at; the mailbox is not persisted
    p = processor(FakeProvider.new)
    handled = []
    p.define_singleton_method(:process_message) do |meta, _result|
      handled << meta.id
      # The run is registered and visible while the fetch is in progress
      raise 'no live run' unless HelpdeskFetchRun.live.where(:mailbox_address => 'support@example.com').exists?
      RedmineExpertHelpdesk::Maintenance.set!(true)
    end
    p.process_all
    assert_equal %w[m1], handled
    assert_equal 0, HelpdeskFetchRun.count
  end

  def test_track_removes_the_row_when_the_block_raises
    assert_raises(RuntimeError) do
      HelpdeskFetchRun.track(@mailbox) { raise 'boom' }
    end
    assert_equal 0, HelpdeskFetchRun.count
  end

  def test_status_ignores_and_purges_stale_runs
    RedmineExpertHelpdesk::Maintenance.set!(true)
    old = (HelpdeskFetchRun::STALE_AFTER + 1.minute).ago
    HelpdeskFetchRun.create!(:mailbox_address => 'dead@example.com', :host => 'pod-gone',
                             :started_at => old, :heartbeat_at => old)
    HelpdeskFetchRun.create!(:mailbox_address => 'live@example.com', :host => 'pod-a',
                             :started_at => Time.current, :heartbeat_at => Time.current)

    status = RedmineExpertHelpdesk::Maintenance.status
    assert_equal %w[live@example.com], status[:running].map { |r| r[:mailbox] }
    assert_equal false, status[:safe_to_stop]
    assert_equal 1, HelpdeskFetchRun.count

    HelpdeskFetchRun.delete_all
    status = RedmineExpertHelpdesk::Maintenance.status
    assert status[:idle]
    assert status[:safe_to_stop]
  end
end
