require File.expand_path('../../test_helper', __FILE__)

# Ticket statistics tab: gated by the member permission
# view_helpdesk_ticket_statistics (menu entry and page alike), renders the
# "no data" branch and a populated page, ignores the business-hours basis
# without SLA.
class HelpdeskTicketStatisticsTest < Redmine::IntegrationTest
  fixtures :projects, :users, :email_addresses, :members, :member_roles, :roles,
           :enabled_modules, :trackers, :projects_trackers, :issue_statuses,
           :enumerations, :issues, :journals, :journal_details

  def setup
    @project = Project.find(1)
    @project.enable_module!(:helpdesk)
    HelpdeskTicketInfo.delete_all
    HelpdeskProjectSetting.where(:project_id => @project.id).delete_all
  end

  def path(params = {})
    p = "/projects/#{@project.identifier}/helpdesk_ticket_statistics"
    params.empty? ? p : "#{p}?#{params.to_query}"
  end

  def grant!
    Role.find(1).add_permission!(:view_helpdesk_ticket_statistics)
  end

  def test_forbidden_without_permission_and_tab_hidden
    Role.find(1).remove_permission!(:view_helpdesk_ticket_statistics)
    log_user('jsmith', 'jsmith') # Manager in project 1

    get "/projects/#{@project.identifier}/issues"
    assert_response :success
    assert_select '#main-menu a.helpdesk-ticket-statistics', 0

    get path
    assert_response :forbidden
  end

  def test_tab_and_page_with_permission_no_data
    grant!
    log_user('jsmith', 'jsmith')

    get "/projects/#{@project.identifier}/issues"
    assert_select '#main-menu a.helpdesk-ticket-statistics'

    get path
    assert_response :success
    assert_select 'p.nodata'
    assert_select 'select#hd-stats-basis', 0, 'no basis toggle without SLA'
  end

  def test_populated_page
    grant!
    issue = Issue.generate!(:project_id => @project.id, :subject => 'stats', :author_id => 3,
                            :assigned_to_id => 2)
    issue.update_columns(:created_on => Time.current - 3600)
    HelpdeskTicketInfo.create!(:issue_id => issue.id, :first_response_at => Time.current - 1800)
    HelpdeskMessage.create!(:issue_id => issue.id, :direction => 'in', :subject => 'q',
                            :sent_at => Time.current - 3600)
    issue.init_journal(User.find(2), 'Answer')
    issue.save!

    log_user('jsmith', 'jsmith')
    get path(:range => 'last_30_days', :period => 'week')
    assert_response :success
    assert_select 'p.nodata', 0
    assert_select 'div.hd-stats-tiles div.hd-stats-tile', :minimum => 6
    assert_select 'table.hd-stats-table', 3
    assert_select 'script#hd-ticket-stats-data'
    assert_select 'a[href=?]', "/users/2", :text => User.find(2).name
    assert_select 'a[href^="mailto:"]', 0
  end

  def test_basis_toggle_only_with_sla
    grant!
    HelpdeskProjectSetting.create!(:project_id => @project.id, :sla_enabled => true,
                                   :sla_reaction_minutes => 60, :sla_solution_minutes => 480)
    log_user('jsmith', 'jsmith')

    get path(:basis => 'business')
    assert_response :success
    assert_select 'select#hd-stats-basis option[selected][value=business]'
  end
end
