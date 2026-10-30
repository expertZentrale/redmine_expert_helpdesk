require File.expand_path('../../test_helper', __FILE__)

# My Page block "awaiting agent": lists the waiting tickets assigned to the user
# and reads each row's ticket info for the chip and the row highlight. It loads
# its own issues (not through IssueQuery#issues), so it preloads them itself.
class HelpdeskMyPageAwaitingTest < Redmine::IntegrationTest
  fixtures :projects, :users, :email_addresses, :members, :member_roles, :roles,
           :enabled_modules, :trackers, :projects_trackers, :issue_statuses,
           :enumerations, :issues, :user_preferences

  def setup
    @issues = Issue.where(:id => [1, 2, 3]).to_a
    @issues.each do |issue|
      HelpdeskTicketInfo.where(:issue_id => issue.id).delete_all
      issue.update_columns(:assigned_to_id => 2)
      HelpdeskTicketInfo.mark_awaiting_agent!(issue, 'reply', Time.current)
    end
    pref = User.find(2).pref
    pref.my_page_layout = { 'top' => ['helpdesk_awaiting_agent'] }
    pref.save!
  end

  def test_block_lists_waiting_tickets_and_loads_their_infos_once
    log_user('jsmith', 'jsmith')

    queries = []
    counter = ->(*, payload) { queries << payload[:sql] if payload[:sql].include?('helpdesk_ticket_infos') }
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') { get '/my/page' }

    assert_response :success
    visible = @issues.select { |issue| issue.visible?(User.find(2)) && !issue.closed? }
    assert_select '.hd-awaiting-chip', visible.size
    assert_select 'tr.hd-awaiting', visible.size
    # COUNT, the list itself, the preload - not one more per row.
    assert_operator queries.size, :<=, 3, queries.join("\n")
  end
end
