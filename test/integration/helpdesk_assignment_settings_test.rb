require File.expand_path('../../test_helper', __FILE__)

# "Assign new tickets to" in the project's Helpdesk tab: what the select offers
# and how it is stored.
class HelpdeskAssignmentSettingsTest < Redmine::IntegrationTest
  fixtures :projects, :users, :email_addresses, :members, :member_roles, :roles,
           :enabled_modules, :trackers, :projects_trackers, :issue_statuses,
           :enumerations, :issues

  def setup
    @project = Project.find(1)
    @project.enable_module!(:helpdesk)
    Role.find(1).add_permission!(:manage_helpdesk, :view_helpdesk_info)
    @group = Group.generate!(:name => 'Second Level')
    User.add_to_project(@group, @project, Role.find(1))
  end

  def settings_tab
    get settings_project_path(@project, :tab => 'expert_helpdesk')
  end

  def test_select_offers_users_and_groups
    with_settings :issue_group_assignment => '1' do
      log_user('jsmith', 'jsmith')
      settings_tab

      assert_response :success
      assert_select 'select#hd_default_assigned_to' do
        assert_select 'option[value=""]'         # "none" - the default
        assert_select 'optgroup', 2              # Users and Groups
        assert_select 'optgroup option[value=?]', @group.id.to_s, :text => 'Second Level'
        assert_select 'optgroup option[value=?]', '2' # jsmith, a plain member
      end
    end
  end

  # assignable_users drops groups when Redmine forbids assigning issues to them,
  # so the select can never offer an assignee core would reject.
  def test_groups_are_hidden_when_redmine_forbids_group_assignment
    with_settings :issue_group_assignment => '0' do
      log_user('jsmith', 'jsmith')
      settings_tab

      assert_response :success
      assert_select 'select#hd_default_assigned_to' do
        assert_select 'optgroup', 1                              # Users only
        assert_select 'option[value=?]', @group.id.to_s, 0
      end
    end
  end

  def test_group_is_stored_and_can_be_cleared_again
    log_user('jsmith', 'jsmith')

    put "/projects/#{@project.identifier}/helpdesk_project_setting",
        :params => { :helpdesk_project_setting => { :default_assigned_to_id => @group.id } }
    assert_response :redirect
    assert_equal @group.id, HelpdeskProjectSetting.for_project(@project).default_assigned_to_id

    put "/projects/#{@project.identifier}/helpdesk_project_setting",
        :params => { :helpdesk_project_setting => { :default_assigned_to_id => '' } }
    assert_nil HelpdeskProjectSetting.for_project(@project).default_assigned_to_id
  end
end
