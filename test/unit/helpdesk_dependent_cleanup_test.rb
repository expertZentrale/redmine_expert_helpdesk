require File.expand_path('../../test_helper', __FILE__)

# Deleting an issue or a project through core Redmine must take the plugin's
# rows with it. Both used to be left behind: ticket infos and messages of
# deleted issues (#47), and contacts of deleted projects, which the API then
# refused to delete even for an admin (#46).
class HelpdeskDependentCleanupTest < ActiveSupport::TestCase
  fixtures :projects, :users, :email_addresses, :members, :member_roles, :roles,
           :enabled_modules, :trackers, :projects_trackers, :issue_statuses,
           :enumerations, :issues

  def new_issue(project = Project.find(1))
    Issue.create!(:project => project, :tracker => project.trackers.first,
                  :author => User.find(1), :subject => 'Helpdesk ticket')
  end

  def test_destroying_an_issue_deletes_its_ticket_info
    issue = new_issue
    HelpdeskTicketInfo.create!(:issue_id => issue.id)

    issue.destroy

    assert_not HelpdeskTicketInfo.where(:issue_id => issue.id).exists?
  end

  # Deleted, not unlinked: issue_id is NOT NULL and a message needs its issue.
  def test_destroying_an_issue_deletes_its_messages
    issue = new_issue
    message = HelpdeskMessage.create!(:issue => issue, :direction => 'in')

    issue.destroy

    assert_not HelpdeskMessage.exists?(message.id)
  end

  def test_destroying_an_issue_leaves_other_issues_alone
    issue = new_issue
    other = new_issue
    HelpdeskTicketInfo.create!(:issue_id => issue.id)
    HelpdeskTicketInfo.create!(:issue_id => other.id)
    kept = HelpdeskMessage.create!(:issue => other, :direction => 'in')

    issue.destroy

    assert HelpdeskTicketInfo.where(:issue_id => other.id).exists?
    assert_equal other.id, kept.reload.issue_id
  end

  def test_destroying_a_project_deletes_its_contacts
    project = Project.create!(:name => 'Throwaway', :identifier => 'helpdesk-throwaway',
                              :tracker_ids => [1])
    contact = HelpdeskContact.create!(:project_id => project.id, :email => 'kunde@example.com')
    issue = new_issue(project)
    HelpdeskTicketInfo.create!(:issue_id => issue.id, :helpdesk_contact_id => contact.id)
    message = HelpdeskMessage.create!(:issue => issue, :direction => 'in', :helpdesk_contact => contact)

    project.destroy

    assert_not HelpdeskContact.exists?(contact.id)
    assert_not HelpdeskTicketInfo.where(:issue_id => issue.id).exists?
    assert_not HelpdeskMessage.exists?(message.id)
  end

  def test_destroying_a_project_keeps_global_and_other_contacts
    project = Project.create!(:name => 'Throwaway', :identifier => 'helpdesk-throwaway')
    global  = HelpdeskContact.create!(:email => 'global@example.com')
    other   = HelpdeskContact.create!(:project_id => 1, :email => 'other@example.com')
    HelpdeskContact.create!(:project_id => project.id, :email => 'gone@example.com')

    project.destroy

    assert HelpdeskContact.exists?(global.id)
    assert HelpdeskContact.exists?(other.id)
  end
end
