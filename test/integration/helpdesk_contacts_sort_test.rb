require File.expand_path('../../test_helper', __FILE__)

# Customer list: sortable through the column headers, including the derived
# ticket-count and last-ticket columns; unknown sort keys fall back to name.
class HelpdeskContactsSortTest < Redmine::IntegrationTest
  fixtures :projects, :users, :email_addresses, :members, :member_roles, :roles,
           :enabled_modules, :trackers, :projects_trackers, :issue_statuses,
           :enumerations, :issues

  def setup
    @project = Project.find(1)
    @project.enable_module!(:helpdesk)
    Role.find(1).add_permission!(:manage_helpdesk_contacts)
    HelpdeskMessage.delete_all
    HelpdeskContact.where(:project_id => @project.id).delete_all

    @alpha = HelpdeskContact.create!(:project_id => @project.id, :email => 'alpha@example.com',
                                     :name => 'Alpha', :company => 'Zeta AG')
    @beta  = HelpdeskContact.create!(:project_id => @project.id, :email => 'beta@example.com',
                                     :name => 'Beta', :company => 'Acme')
    HelpdeskMessage.create!(:issue_id => 1, :helpdesk_contact_id => @beta.id, :direction => 'in',
                            :subject => 'a', :sent_at => Time.current - 1.day)
    HelpdeskMessage.create!(:issue_id => 2, :helpdesk_contact_id => @beta.id, :direction => 'in',
                            :subject => 'b', :sent_at => Time.current)
    HelpdeskMessage.create!(:issue_id => 3, :helpdesk_contact_id => @alpha.id, :direction => 'in',
                            :subject => 'c', :sent_at => Time.current - 3.days)
    log_user('jsmith', 'jsmith')
  end

  def names(sort = nil)
    get "/projects/#{@project.identifier}/helpdesk_contacts", :params => { :sort => sort }.compact
    assert_response :success
    css_select('table.list tbody tr td:first-child strong').map { |n| n.text.strip }
  end

  def test_default_sorts_by_name
    assert_equal %w[Alpha Beta], names
    assert_select 'table.list thead th a[href*="sort=ticket_count"]'
  end

  def test_sort_by_ticket_count_desc
    assert_equal %w[Beta Alpha], names('ticket_count:desc')
  end

  def test_sort_by_last_ticket_and_company
    assert_equal %w[Beta Alpha], names('last_ticket:desc')
    assert_equal %w[Beta Alpha], names('company:asc')
  end

  def test_unknown_sort_key_falls_back
    assert_equal %w[Alpha Beta], names('bogus:desc')
  end
end
