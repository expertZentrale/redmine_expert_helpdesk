require File.expand_path('../../test_helper', __FILE__)

# "Awaiting agent" flag: set when a customer replies by mail, cleared when an agent
# answers publicly or closes the ticket.
class HelpdeskAwaitingAgentTest < ActiveSupport::TestCase
  fixtures :all

  def setup
    @issue = Issue.find(1)
    HelpdeskTicketInfo.where(:issue_id => @issue.id).delete_all
  end

  # -----------------------------------------------------------------------
  # mark_awaiting_agent!
  # -----------------------------------------------------------------------

  def test_mark_sets_timestamp_and_reason
    at = Time.current.change(:usec => 0)
    info = HelpdeskTicketInfo.mark_awaiting_agent!(@issue, 'reply', at)

    assert_not_nil info
    assert_equal at.to_i, info.awaiting_agent_since.to_i
    assert_equal 'reply', info.awaiting_agent_reason
  end

  def test_mark_creates_row_when_missing
    assert_nil HelpdeskTicketInfo.for_issue(@issue)
    HelpdeskTicketInfo.mark_awaiting_agent!(@issue, 'reply', Time.current)
    assert_not_nil HelpdeskTicketInfo.for_issue(@issue)
  end

  # The waiting age must stay at the OLDEST unanswered reply, so a second reply
  # does not make the ticket look fresh.
  def test_second_mark_does_not_reset_since
    first = 3.days.ago.change(:usec => 0)
    HelpdeskTicketInfo.mark_awaiting_agent!(@issue, 'reply', first)
    HelpdeskTicketInfo.mark_awaiting_agent!(@issue, 'reply', Time.current)

    assert_equal first.to_i, HelpdeskTicketInfo.for_issue(@issue).awaiting_agent_since.to_i
  end

  def test_second_mark_upgrades_reason_to_reopen
    HelpdeskTicketInfo.mark_awaiting_agent!(@issue, 'reply', 3.days.ago)
    HelpdeskTicketInfo.mark_awaiting_agent!(@issue, 'reopen', Time.current)

    assert_equal 'reopen', HelpdeskTicketInfo.for_issue(@issue).awaiting_agent_reason
  end

  def test_reopen_reason_is_not_downgraded_to_reply
    HelpdeskTicketInfo.mark_awaiting_agent!(@issue, 'reopen', 3.days.ago)
    HelpdeskTicketInfo.mark_awaiting_agent!(@issue, 'reply', Time.current)

    assert_equal 'reopen', HelpdeskTicketInfo.for_issue(@issue).awaiting_agent_reason
  end

  def test_unknown_reason_falls_back_to_reply
    HelpdeskTicketInfo.mark_awaiting_agent!(@issue, 'nonsense', Time.current)
    assert_equal 'reply', HelpdeskTicketInfo.for_issue(@issue).awaiting_agent_reason
  end

  # -----------------------------------------------------------------------
  # clear_awaiting_agent!
  # -----------------------------------------------------------------------

  def test_clear_nulls_both_columns
    HelpdeskTicketInfo.mark_awaiting_agent!(@issue, 'reopen', Time.current)
    HelpdeskTicketInfo.clear_awaiting_agent!(@issue)

    info = HelpdeskTicketInfo.for_issue(@issue)
    assert_nil info.awaiting_agent_since
    assert_nil info.awaiting_agent_reason
  end

  # It must never create a row just to clear it.
  def test_clear_is_a_noop_without_a_row
    assert_nil HelpdeskTicketInfo.for_issue(@issue)
    assert_nothing_raised { HelpdeskTicketInfo.clear_awaiting_agent!(@issue) }
    assert_nil HelpdeskTicketInfo.for_issue(@issue)
  end

  # -----------------------------------------------------------------------
  # Scope and issue accessor
  # -----------------------------------------------------------------------

  def test_awaiting_agent_scope_selects_only_flagged_rows
    other = Issue.find(2)
    HelpdeskTicketInfo.where(:issue_id => other.id).delete_all
    HelpdeskTicketInfo.mark_awaiting_agent!(@issue, 'reply', Time.current)
    HelpdeskTicketInfo.create!(:issue_id => other.id)

    ids = HelpdeskTicketInfo.awaiting_agent.pluck(:issue_id)
    assert_includes ids, @issue.id
    assert_not_includes ids, other.id
  end

  def test_issue_helpdesk_awaiting_agent_returns_since_and_reason
    at = Time.current.change(:usec => 0)
    HelpdeskTicketInfo.mark_awaiting_agent!(@issue, 'reopen', at)

    since, reason = Issue.find(@issue.id).helpdesk_awaiting_agent
    assert_equal at.to_i, since.to_i
    assert_equal 'reopen', reason
  end

  def test_issue_helpdesk_awaiting_agent_is_nil_when_not_waiting
    assert_nil Issue.find(@issue.id).helpdesk_awaiting_agent
  end

  # -----------------------------------------------------------------------
  # Row highlighting
  # -----------------------------------------------------------------------

  def test_css_classes_include_hd_awaiting_when_flagged
    HelpdeskTicketInfo.mark_awaiting_agent!(@issue, 'reply', Time.current)
    assert_includes Issue.find(@issue.id).css_classes.split, 'hd-awaiting'
  end

  def test_css_classes_omit_hd_awaiting_when_not_flagged
    assert_not_includes Issue.find(@issue.id).css_classes.split, 'hd-awaiting'
  end

  # -----------------------------------------------------------------------
  # Query filter
  # -----------------------------------------------------------------------

  def test_filter_selects_waiting_issues
    HelpdeskTicketInfo.mark_awaiting_agent!(@issue, 'reply', Time.current)

    query = IssueQuery.new(:name => '_')
    query.add_filter('helpdesk_awaiting_agent', '=', ['1'])
    ids = query.issues.map(&:id)

    assert_includes ids, @issue.id
    assert_not_includes ids, Issue.find(2).id
  end

  def test_filter_selects_non_waiting_issues
    HelpdeskTicketInfo.mark_awaiting_agent!(@issue, 'reply', Time.current)

    query = IssueQuery.new(:name => '_')
    query.add_filter('helpdesk_awaiting_agent', '=', ['0'])
    ids = query.issues.map(&:id)

    assert_not_includes ids, @issue.id
  end

  # -----------------------------------------------------------------------
  # Global switch
  # -----------------------------------------------------------------------

  def with_awaiting_disabled
    previous = Setting.plugin_redmine_expert_helpdesk
    Setting.plugin_redmine_expert_helpdesk = previous.merge('awaiting_agent_enabled' => '0')
    yield
  ensure
    Setting.plugin_redmine_expert_helpdesk = previous
  end

  # Turning the feature off must hide chips and row highlights for tickets that
  # were flagged while it was on.
  def test_accessor_returns_nil_when_feature_is_disabled
    HelpdeskTicketInfo.mark_awaiting_agent!(@issue, 'reply', Time.current)

    with_awaiting_disabled do
      assert_not HelpdeskTicketInfo.awaiting_agent_enabled?
      assert_nil Issue.find(@issue.id).helpdesk_awaiting_agent
    end
  end

  def test_css_classes_omit_hd_awaiting_when_feature_is_disabled
    HelpdeskTicketInfo.mark_awaiting_agent!(@issue, 'reply', Time.current)

    with_awaiting_disabled do
      assert_not_includes Issue.find(@issue.id).css_classes.split, 'hd-awaiting'
    end
  end

  # -----------------------------------------------------------------------
  # Sort order
  # -----------------------------------------------------------------------

  # Ascending must put waiting tickets first, oldest wait first -- clicking the
  # column is meant to surface who has been waiting longest.
  def test_sort_puts_waiting_tickets_first_ascending
    waiting_old = Issue.find(1)
    waiting_new = Issue.find(2)
    [waiting_old, waiting_new].each { |i| HelpdeskTicketInfo.where(:issue_id => i.id).delete_all }
    HelpdeskTicketInfo.mark_awaiting_agent!(waiting_old, 'reply', 5.days.ago)
    HelpdeskTicketInfo.mark_awaiting_agent!(waiting_new, 'reply', 1.hour.ago)

    query = IssueQuery.new(:name => '_')
    query.sort_criteria = [['helpdesk_awaiting_agent', 'asc']]
    ids = query.issues.map(&:id)

    assert_equal waiting_old.id, ids.first, 'longest-waiting ticket must sort first'
    assert_operator ids.index(waiting_old.id), :<, ids.index(waiting_new.id)
  end

  def test_awaiting_agent_column_is_available
    assert IssueQuery.new(:name => '_').available_columns.any? { |c| c.name == :helpdesk_awaiting_agent }
  end

  # -----------------------------------------------------------------------
  # Auto-reopen (MailProcessor)
  # -----------------------------------------------------------------------

  # Minimal stand-in for the mail provider -- no provider calls happen here.
  NullProvider = Class.new do
    def method_missing(*); nil; end
    def respond_to_missing?(*); true; end
  end

  def processor_for(reopen_status_id)
    mailbox = HelpdeskMailbox.new(:reopen_status_id => reopen_status_id)
    RedmineExpertHelpdesk::MailProcessor.new(mailbox, NullProvider.new)
  end

  def closed_issue
    closed = IssueStatus.where(:is_closed => true).first
    issue = Issue.find(1)
    issue.update_columns(:status_id => closed.id)
    [Issue.find(issue.id), closed]
  end

  def test_reopen_is_a_noop_on_an_open_issue
    open_status = IssueStatus.where(:is_closed => false).first
    issue = Issue.find(1)
    issue.update_columns(:status_id => open_status.id)

    processor = processor_for(IssueStatus.where(:is_closed => false).last.id)
    assert_equal false, processor.send(:reopen_if_closed, Issue.find(issue.id), nil)
  end

  def test_reopen_is_a_noop_without_a_configured_status
    issue, = closed_issue
    assert_equal false, processor_for(nil).send(:reopen_if_closed, issue, nil)
  end

  # Guard against writing an empty status detail.
  def test_reopen_is_a_noop_when_status_already_matches
    issue, closed = closed_issue
    assert_equal false, processor_for(closed.id).send(:reopen_if_closed, issue, nil)
  end

  def test_reopen_sets_the_configured_status
    issue, = closed_issue
    target = IssueStatus.where(:is_closed => false).first

    assert_equal true, processor_for(target.id).send(:reopen_if_closed, issue, nil)
    assert_equal target.id, Issue.find(issue.id).status_id
  end

  # The reopen must be visible in the history: the status detail is attached to the
  # journal the inbound reply already created.
  def test_reopen_adds_a_status_detail_to_the_given_journal
    issue, closed = closed_issue
    target = IssueStatus.where(:is_closed => false).first
    journal = Journal.create!(:journalized => issue, :user => User.find(1), :notes => 'Kundenantwort')

    processor_for(target.id).send(:reopen_if_closed, issue, journal)

    detail = journal.reload.details.detect { |d| d.prop_key == 'status_id' }
    assert_not_nil detail, 'expected a status_id detail on the reply journal'
    assert_equal closed.id.to_s, detail.old_value
    assert_equal target.id.to_s, detail.value
  end

  # Fallback path: no journal to attach to, so a silent one is created.
  def test_reopen_creates_a_journal_when_none_is_given
    issue, = closed_issue
    target = IssueStatus.where(:is_closed => false).first

    assert_difference 'Journal.count', 1 do
      processor_for(target.id).send(:reopen_if_closed, issue, nil)
    end
  end
end
