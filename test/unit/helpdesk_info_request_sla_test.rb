require File.expand_path('../../test_helper', __FILE__)

# An automatic follow-up must not touch the SLA clocks: it is the plugin talking,
# not an agent reacting and not a problem being solved.
class HelpdeskInfoRequestSlaTest < ActiveSupport::TestCase
  fixtures :projects, :issues, :issue_statuses, :users, :trackers, :enumerations,
           :roles, :members, :member_roles

  def setup
    # A fresh issue, not a fixture one: the fixtures were created long ago, so both
    # clocks would already read :breached and every assertion below would pass for
    # the wrong reason.
    @issue = Issue.generate!(:project_id => 1, :subject => 'SLA follow-up',
                             :description => 'kaputt')
    @issue.update_columns(:created_on => Time.current)
    @ps = HelpdeskProjectSetting.find_or_initialize_by(:project_id => @issue.project_id)
    @ps.assign_attributes(:info_request_mode => 'heuristic', :info_request_min_chars => 100,
                          :info_request_min_words => 0, :info_request_threshold => 1,
                          :sla_enabled => true, :sla_reaction_minutes => 60,
                          :sla_solution_minutes => 480, :sla_work_days => '1,2,3,4,5',
                          :sla_work_start => '08:00', :sla_work_end => '17:00')
    @ps.save!
    RedmineExpertHelpdesk::Sla.refresh_deadlines!(@issue)

    contact = HelpdeskContact.create!(:project_id => @issue.project_id,
                                      :email => 'sla-kunde@example.com')
    mailbox = HelpdeskMailbox.create!(:project_id => @issue.project_id,
                                      :mailbox_address => 'hd-sla@example.com')
    # refresh_deadlines! already created the row, so update it instead of creating one.
    HelpdeskTicketInfo.find_or_initialize_by(:issue_id => @issue.id)
                      .update!(:helpdesk_contact_id => contact.id,
                               :helpdesk_mailbox_id => mailbox.id)
    Setting.stubs(:plugin_redmine_expert_helpdesk).returns({ 'info_request_enabled' => '1' })
  end

  def closed_status
    IssueStatus.where(:is_closed => true).first
  end

  def open_status
    IssueStatus.where(:is_closed => false).where.not(:id => @issue.status_id).first
  end

  def run_job!
    # Only the mail leaves the box in a real run; the note and the status change
    # are what this test is about, so let them happen.
    RedmineExpertHelpdesk::InfoRequestMailer.stubs(:deliver).returns(true)
    HelpdeskCompletenessJob.perform_now(@issue.id)
    Issue.find(@issue.id)
  end

  # Sanity: the note went out, so the job really ran.
  def assert_followed_up(issue)
    assert_equal 1, HelpdeskTicketInfo.for_issue(issue).info_request_count
  end

  # The note alone must not stop the reaction clock.
  def test_follow_up_note_does_not_stop_the_reaction_clock
    @ps.update!(:info_request_status_id => nil)
    issue = run_job!
    assert_followed_up(issue)

    assert_nil HelpdeskTicketInfo.for_issue(issue).first_response_at,
               'the automatic note must not count as the first response'
    assert_equal :running, issue.helpdesk_sla_reaction
    assert_equal :running, issue.helpdesk_sla_solution
  end

  # The reported bug: a configured status that happens to be closed marked BOTH
  # clocks done, because every SLA reader treats closed_on as "done".
  def test_follow_up_never_closes_the_ticket
    @ps.update!(:info_request_status_id => closed_status.id)
    issue = run_job!
    assert_followed_up(issue)

    assert_not issue.closed?, 'an automatic follow-up must not close the ticket'
    assert_equal :running, issue.helpdesk_sla_reaction
    assert_equal :running, issue.helpdesk_sla_solution
  end

  # A normal "waiting for customer" status must still be applied.
  def test_open_status_is_still_applied
    target = open_status
    @ps.update!(:info_request_status_id => target.id)
    issue = run_job!
    assert_followed_up(issue)

    assert_equal target.id, issue.status_id
    assert_equal :running, issue.helpdesk_sla_reaction
    assert_equal :running, issue.helpdesk_sla_solution
  end
end
