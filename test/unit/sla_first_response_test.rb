require File.expand_path('../../test_helper', __FILE__)

# The first reaction is recorded for every helpdesk ticket, SLA or not; only the
# business-minute figure is an SLA feature and rows are only created under SLA.
class SlaFirstResponseTest < ActiveSupport::TestCase
  fixtures :projects, :issues, :issue_statuses, :users, :trackers, :enumerations,
           :roles, :members, :member_roles

  def setup
    @issue = Issue.generate!(:project_id => 1, :subject => 'first response')
    @issue.update_columns(:created_on => Time.current - 3600)
    HelpdeskProjectSetting.where(:project_id => 1).delete_all
    HelpdeskTicketInfo.where(:issue_id => @issue.id).delete_all
  end

  def test_without_sla_updates_existing_row_without_business_minutes
    HelpdeskTicketInfo.create!(:issue_id => @issue.id)
    at = Time.current

    RedmineExpertHelpdesk::Sla.record_first_response!(@issue, at, :by => User.find(2))

    info = HelpdeskTicketInfo.for_issue(@issue)
    assert_in_delta at.to_i, info.first_response_at.to_i, 1
    assert_nil info.reaction_business_minutes
    assert_equal 2, info.first_response_by_id
  end

  def test_anonymous_actor_leaves_first_response_by_empty
    HelpdeskTicketInfo.create!(:issue_id => @issue.id)
    RedmineExpertHelpdesk::Sla.record_first_response!(@issue, Time.current, :by => User.anonymous)

    info = HelpdeskTicketInfo.for_issue(@issue)
    assert_not_nil info.first_response_at
    assert_nil info.first_response_by_id
  end

  def test_without_sla_never_creates_a_row
    RedmineExpertHelpdesk::Sla.record_first_response!(@issue, Time.current)

    assert_nil HelpdeskTicketInfo.for_issue(@issue)
  end

  def test_with_sla_creates_row_and_business_minutes
    HelpdeskProjectSetting.create!(:project_id => 1, :sla_enabled => true,
                                   :sla_reaction_minutes => 60, :sla_solution_minutes => 480,
                                   :sla_work_days => '1,2,3,4,5,6,7',
                                   :sla_work_start => '00:00', :sla_work_end => '23:59')

    RedmineExpertHelpdesk::Sla.record_first_response!(@issue, Time.current)

    info = HelpdeskTicketInfo.for_issue(@issue)
    assert_not_nil info
    assert_not_nil info.first_response_at
    assert_in_delta 60, info.reaction_business_minutes, 2
  end

  def test_first_response_is_write_once
    HelpdeskTicketInfo.create!(:issue_id => @issue.id)
    first = Time.current - 600
    RedmineExpertHelpdesk::Sla.record_first_response!(@issue, first)
    RedmineExpertHelpdesk::Sla.record_first_response!(@issue, Time.current)

    assert_in_delta first.to_i, HelpdeskTicketInfo.for_issue(@issue).first_response_at.to_i, 1
  end
end
