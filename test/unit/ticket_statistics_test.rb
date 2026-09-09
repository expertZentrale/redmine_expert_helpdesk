require File.expand_path('../../test_helper', __FILE__)

# Pure folds of the ticket statistics (no DB): message classification, status
# timelines, reopen detection, agent replies, the per-ticket fold and the tables.
class TicketStatisticsTest < ActiveSupport::TestCase
  TS = RedmineExpertHelpdesk::TicketStatistics

  T0      = Time.local(2026, 3, 2, 9, 0)
  NEW     = 1
  WORK    = 2
  CLOSED  = 5
  CLOSED_IDS = Set[CLOSED]
  ANON    = 2
  AGENT   = 10
  AGENT2  = 11
  CUSTOMER = 20
  WALL = ->(from, to) { from && to && to >= from ? ((to - from) / 60.0).round : nil }

  def ticket(**attrs)
    defaults = { :id => 1, :created_on => T0, :closed_on => nil, :status_id => NEW,
                 :assigned_to_id => AGENT, :author_id => CUSTOMER, :first_response_at => nil,
                 :first_response_by_id => nil, :reaction_minutes => nil, :solution_minutes => nil, :awaiting_agent_since => nil,
                 :contact_id => 100 }
    TS::TicketRow.new(*defaults.merge(attrs).values_at(*TS::TicketRow.members))
  end

  def journal(id, at, user, notes: true, private_notes: false, from: nil, to: nil)
    TS::JournalRow.new(id, 1, user, at, private_notes, notes, from ? id * 10 : nil, from, to)
  end

  def mail(direction, at, journal_id: nil, message_id: nil)
    TS::MessageRow.new(1, direction, journal_id, message_id, at)
  end

  def fold(ticket, journals = [], messages = [], business_hours: false)
    TS.ticket_metrics(ticket, journals, messages, :closed_ids => CLOSED_IDS, :anonymous_id => ANON,
                      :duration => WALL, :business_hours => business_hours)
  end

  # --- classify_message --------------------------------------------------------

  def test_classify_message
    assert_equal :incoming,  TS.classify_message('in', nil, nil)
    assert_equal :agent,     TS.classify_message('out', 7, nil)
    assert_equal :agent,     TS.classify_message('out', nil, '<id@x>')
    assert_equal :automated, TS.classify_message('out', nil, nil)
    assert_nil TS.classify_message('init', nil, nil)
  end

  # --- status_timeline / reopen_count -------------------------------------------

  def test_timeline_without_transitions
    tl = TS.status_timeline(T0, WORK, [])
    assert_equal WORK, tl.initial_status_id
    assert_equal [], tl.segments
    assert_equal WORK, tl.current_status_id
    assert_equal T0, tl.current_since
  end

  def test_timeline_segments_follow_old_value
    tr = [[T0 + 3600, NEW, WORK, AGENT], [T0 + 7200, WORK, CLOSED, AGENT]]
    tl = TS.status_timeline(T0, CLOSED, tr)
    assert_equal NEW, tl.initial_status_id
    assert_equal [[NEW, T0, T0 + 3600], [WORK, T0 + 3600, T0 + 7200]], tl.segments
    assert_equal T0 + 7200, tl.current_since
  end

  def test_reopen_count
    tr = [[T0 + 1, NEW, CLOSED], [T0 + 2, CLOSED, WORK], [T0 + 3, WORK, CLOSED], [T0 + 4, CLOSED, NEW]]
    assert_equal 2, TS.reopen_count(tr, CLOSED_IDS)
    assert_equal 0, TS.reopen_count([[T0, NEW, WORK]], CLOSED_IDS)
  end

  # --- agent_reply? ----------------------------------------------------------------

  def test_agent_reply_rules
    args = { :anonymous_id => ANON, :incoming_journal_ids => Set[3], :author_id => CUSTOMER,
             :customer_created => true }
    assert TS.agent_reply?(journal(1, T0, AGENT), **args)
    assert_not TS.agent_reply?(journal(2, T0, AGENT, :private_notes => true), **args)
    assert_not TS.agent_reply?(journal(3, T0, AGENT), **args), 'MailHandler journal of a customer mail'
    assert_not TS.agent_reply?(journal(4, T0, ANON), **args)
    assert_not TS.agent_reply?(journal(5, T0, CUSTOMER), **args), 'author of a customer-created ticket'
    assert TS.agent_reply?(journal(5, T0, CUSTOMER), **args.merge(:customer_created => false)),
           'author of an agent-created ticket is the agent'
    assert_not TS.agent_reply?(journal(6, T0, AGENT, :notes => false), **args)
  end

  # --- ticket_metrics -----------------------------------------------------------------

  def test_metrics_of_a_closed_customer_ticket
    t = ticket(:status_id => CLOSED, :closed_on => T0 + 4 * 3600, :first_response_at => T0 + 1800)
    journals = [journal(1, T0 + 1800, AGENT), journal(2, T0 + 3600, CUSTOMER),
                journal(3, T0 + 4 * 3600, AGENT2, :from => WORK, :to => CLOSED),
                journal(4, T0 + 2000, AGENT, :notes => false, :from => NEW, :to => WORK)]
    messages = [mail('in', T0), mail('in', T0 + 3600, :journal_id => 2),
                mail('out', T0 + 1800, :journal_id => 1), mail('out', T0 + 60)]
    m = fold(t, journals, messages)

    assert m.closed
    assert m.customer_created
    assert_equal 30, m.first_response_minutes
    assert_equal 240, m.resolution_minutes
    assert_equal 2, m.incoming
    assert_equal 2, m.agent_replies
    assert_equal 1, m.automated
    assert_equal AGENT, m.first_reply_user_id
    assert_equal [AGENT, AGENT2], m.reply_user_ids
    assert_equal AGENT2, m.closed_by_user_id
    assert_equal 0, m.reopen_count
    # segments are built from the transitions sorted by the caller (journal order)
    assert_equal [[WORK, 0], [NEW, 0]].map(&:first).sort, m.segment_minutes.map(&:first).sort
  end

  def test_stale_closed_on_on_reopened_ticket_is_ignored
    t = ticket(:status_id => WORK, :closed_on => T0 + 3600)
    m = fold(t, [journal(1, T0 + 3600, AGENT, :from => NEW, :to => CLOSED),
                 journal(2, T0 + 7200, ANON, :from => CLOSED, :to => WORK)])
    assert_not m.closed
    assert_nil m.closed_on
    assert_nil m.resolution_minutes
    assert_equal 1, m.reopen_count
    assert_equal [[NEW, 60], [CLOSED, 60]], m.segment_minutes
  end

  def test_journal_before_created_on_never_yields_negative_minutes
    t = ticket(:created_on => T0 + 3600)
    m = fold(t, [journal(1, T0, AGENT, :from => NEW, :to => WORK)])
    assert_equal [[NEW, 0]], m.segment_minutes
  end

  def test_agent_created_ticket_counts_author_replies
    t = ticket(:author_id => AGENT)
    m = fold(t, [journal(1, T0 + 60, AGENT)], [mail('init', T0)])
    assert_not m.customer_created
    assert_equal 1, m.agent_replies
  end

  def test_business_hours_prefers_stored_minutes
    t = ticket(:status_id => CLOSED, :closed_on => T0 + 3600, :first_response_at => T0 + 1800,
               :reaction_minutes => 7, :solution_minutes => 9)
    m = fold(t, [], [], :business_hours => true)
    assert_equal 7, m.first_response_minutes
    assert_equal 9, m.resolution_minutes
    m = fold(t)
    assert_equal 30, m.first_response_minutes
    assert_equal 60, m.resolution_minutes
  end

  def test_first_response_by_prefers_recorded_user_over_journal
    t = ticket(:first_response_at => T0 + 60, :first_response_by_id => AGENT2)
    m = fold(t, [journal(1, T0 + 120, AGENT)])
    assert_equal AGENT2, m.first_reply_user_id
    assert_equal 1, m.first_response_minutes

    m = fold(ticket(:first_response_at => T0 + 60), [journal(1, T0 + 120, AGENT)])
    assert_equal AGENT, m.first_reply_user_id, 'falls back to the first agent reply'

    m = fold(ticket(:first_response_at => T0 + 60, :first_response_by_id => ANON))
    assert_nil m.first_reply_user_id
  end

  def test_anonymous_close_is_unattributed
    t = ticket(:status_id => CLOSED, :closed_on => T0 + 60)
    m = fold(t, [journal(1, T0 + 60, ANON, :notes => false, :from => NEW, :to => CLOSED)])
    assert_nil m.closed_by_user_id
  end

  # --- tables ---------------------------------------------------------------------------

  def metrics_fixture
    a = fold(ticket(:id => 1, :status_id => CLOSED, :closed_on => T0 + 600, :first_response_at => T0 + 300),
             [journal(1, T0 + 300, AGENT), journal(2, T0 + 600, AGENT, :notes => false, :from => NEW, :to => CLOSED)],
             [mail('in', T0)])
    b = fold(ticket(:id => 2, :assigned_to_id => 99, :contact_id => 101, :status_id => WORK),
             [journal(3, T0 + 60, AGENT2, :notes => false, :from => NEW, :to => WORK), journal(4, T0 + 120, AGENT2)],
             [mail('in', T0), mail('in', T0 + 30), mail('in', T0 + 40), mail('out', T0 + 5)])
    c = fold(ticket(:id => 3, :assigned_to_id => nil, :contact_id => nil, :awaiting_agent_since => T0),
             [], [mail('in', T0)])
    [a, b, c]
  end

  def test_totals
    t = TS.totals(metrics_fixture)
    assert_equal 3, t[:tickets]
    assert_equal 2, t[:open]
    assert_equal 1, t[:closed]
    assert_equal 1, t[:awaiting_agent]
    assert_equal 5, t[:first_response_median]
    assert_equal 10, t[:resolution_mean]
    assert_equal 1, t[:one_touch]
    assert_equal 100.0, t[:one_touch_ratio]
    assert_equal 1, t[:automated_mails]
  end

  def test_status_table_only_lists_seen_statuses
    statuses = [[NEW, 'New', false], [WORK, 'In progress', false], [4, 'Unused', false], [CLOSED, 'Closed', true]]
    rows = TS.status_table(metrics_fixture, statuses)
    assert_equal [NEW, WORK, CLOSED], rows.map { |r| r[:id] }
    new_row = rows.find { |r| r[:id] == NEW }
    assert_equal 3, new_row[:initial]
    assert_equal 3, new_row[:tickets]
    assert_equal 1, new_row[:current]
    assert_equal 2, new_row[:dwell_count]
    assert_equal 6, new_row[:dwell_median] # (10 + 1) / 2 -> 5.5 -> 6
    closed_row = rows.find { |r| r[:id] == CLOSED }
    assert closed_row[:closed]
    assert_equal 1, closed_row[:current]
    assert_equal 0, closed_row[:dwell_count]
  end

  def test_agent_table_merges_assignee_and_reply_views
    rows = TS.agent_table(metrics_fixture)
    assert_nil rows.last[:principal_id], 'unassigned row last'
    agent = rows.find { |r| r[:principal_id] == AGENT }
    assert_equal 1, agent[:assigned]
    assert_equal 1, agent[:closed]
    assert_equal 1, agent[:replies]
    assert_equal 1, agent[:closed_by]
    assert_equal 5, agent[:first_response_median]
    assert_equal 10, agent[:resolution_median]
    group = rows.find { |r| r[:principal_id] == 99 }
    assert_equal 1, group[:assigned]
    assert_equal 0, group[:replies]
    agent2 = rows.find { |r| r[:principal_id] == AGENT2 }
    assert_equal 0, agent2[:assigned]
    assert_equal 1, agent2[:replies]
  end

  def test_customer_table_limits_and_appends_no_contact
    rows = TS.customer_table(metrics_fixture, :limit => 1)
    assert_equal [101, nil], rows.map { |r| r[:contact_id] }
    assert_equal 3, rows.first[:incoming]
    assert_equal 1, rows.first[:replies]
  end

  def test_conversation_buckets
    c = TS.conversation(metrics_fixture)
    assert_equal({ '0' => 0, '1' => 2, '2' => 0, '3-5' => 1, '6-10' => 0, '>10' => 0 },
                 c[:buckets].to_h { |b| [b[:key], b[:tickets]] })
    assert_equal 1, c[:incoming_median]
    assert_equal 2, c[:incoming_mean]
    assert_equal '>10', TS.conversation_bucket(42)
  end
end
