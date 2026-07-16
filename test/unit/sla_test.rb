require File.expand_path('../../test_helper', __FILE__)

# Tests fuer die SLA-Statusberechnung (clock_state).
class SlaTest < ActiveSupport::TestCase
  SettingStub = Struct.new(:sla_work_days_array, :sla_work_start, :sla_work_end)
  IssueStub   = Struct.new(:created_on)

  def setup
    # Rund-um-die-Uhr-Arbeitszeit macht die Rechnung im Test vorhersagbar
    @setting = SettingStub.new([1, 2, 3, 4, 5, 6, 7], '00:00', '23:59')
  end

  def clock(created_ago_minutes, target, done_at = nil, done_minutes = nil)
    issue = IssueStub.new(Time.current - created_ago_minutes * 60)
    RedmineExpertHelpdesk::Sla.clock_state(issue, target, done_at, done_minutes, @setting)
  end

  def test_nil_without_target
    assert_nil clock(100, nil)
    assert_nil clock(100, 0)
  end

  def test_met_when_done_within_target
    state = clock(100, 60, Time.current, 45)
    assert_equal :met, state[:status]
    assert_equal 45, state[:minutes]
  end

  def test_breached_done_when_done_after_target
    state = clock(100, 60, Time.current, 90)
    assert_equal :breached_done, state[:status]
  end

  def test_running_below_warning_threshold
    state = clock(30, 60)
    assert_equal :running, state[:status]
    assert_not_nil state[:due_at]
  end

  def test_warning_above_80_percent
    state = clock(50, 60)
    assert_equal :warning, state[:status]
  end

  def test_breached_when_over_target
    state = clock(90, 60)
    assert_equal :breached, state[:status]
  end

  def test_done_minutes_computed_when_not_stored
    issue = IssueStub.new(Time.current - 120 * 60)
    done  = issue.created_on + 30 * 60
    state = RedmineExpertHelpdesk::Sla.clock_state(issue, 60, done, nil, @setting)
    assert_equal :met, state[:status]
    assert_in_delta 30, state[:minutes], 1
  end

  # --- clock_status_from: Statusableitung aus gespeicherten Faelligkeiten ----

  def test_status_from_nil_without_due
    assert_nil RedmineExpertHelpdesk::Sla.clock_status_from(nil, nil, nil)
    assert_nil RedmineExpertHelpdesk::Sla.clock_status_from(nil, Time.current, Time.current)
  end

  def test_status_from_met_when_done_before_due
    due = Time.current + 60 * 60
    assert_equal :met, RedmineExpertHelpdesk::Sla.clock_status_from(due, nil, Time.current)
  end

  def test_status_from_breached_done_when_done_after_due
    due  = Time.current - 60 * 60
    done = Time.current
    assert_equal :breached_done, RedmineExpertHelpdesk::Sla.clock_status_from(due, nil, done)
  end

  def test_status_from_running_before_warning
    due  = Time.current + 60 * 60
    warn = Time.current + 30 * 60
    assert_equal :running, RedmineExpertHelpdesk::Sla.clock_status_from(due, warn, nil)
  end

  def test_status_from_warning_between_warn_and_due
    due  = Time.current + 30 * 60
    warn = Time.current - 5 * 60
    assert_equal :warning, RedmineExpertHelpdesk::Sla.clock_status_from(due, warn, nil)
  end

  def test_status_from_breached_when_now_past_due
    due  = Time.current - 5 * 60
    warn = Time.current - 30 * 60
    assert_equal :breached, RedmineExpertHelpdesk::Sla.clock_status_from(due, warn, nil)
  end

  def test_status_from_running_when_no_warn_at
    due = Time.current + 30 * 60
    assert_equal :running, RedmineExpertHelpdesk::Sla.clock_status_from(due, nil, nil)
  end
end
