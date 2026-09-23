require File.expand_path('../../test_helper', __FILE__)

# The reply block's colours reach the edit form, and the project form stores them.
class HelpdeskReplyBoxTest < Redmine::IntegrationTest
  fixtures :projects, :users, :email_addresses, :members, :member_roles, :roles,
           :enabled_modules, :trackers, :projects_trackers, :issue_statuses,
           :enumerations, :issues, :journals

  def setup
    @project = Project.find(1)
    @project.enable_module!(:helpdesk)
    Role.find(1).add_permission!(:manage_helpdesk, :send_helpdesk_reply, :view_helpdesk_info)
    HelpdeskProjectSetting.where(:project_id => @project.id).delete_all
  end

  def test_the_project_form_stores_and_clears_the_colours
    log_user('jsmith', 'jsmith')

    put "/projects/#{@project.identifier}/helpdesk_project_setting",
        :params => { :reply_box_form => '1',
                     :helpdesk_project_setting => { :reply_box_color => '#aabbcc',
                                                    :reply_hazard_color => '#ddeeff' } }
    setting = HelpdeskProjectSetting.for_project(@project)
    assert_equal '#aabbcc', setting.effective_reply_box_color
    assert_equal '#ddeeff', setting.effective_reply_hazard_color

    put "/projects/#{@project.identifier}/helpdesk_project_setting",
        :params => { :reply_box_form => '1',
                     :helpdesk_project_setting => { :reply_box_color => '',
                                                    :reply_hazard_color => '' } }
    setting = HelpdeskProjectSetting.for_project(@project)
    assert_nil setting.reply_box_color
    assert_equal RedmineExpertHelpdesk::ReplyBox::DEFAULT_BOX_COLOR,
                 setting.effective_reply_box_color
  end

  # A colour that is not a colour must not end up in the stylesheet; the model
  # validation rejects it and the controller's rescue turns that into a flash.
  def test_a_non_colour_is_rejected
    log_user('jsmith', 'jsmith')

    put "/projects/#{@project.identifier}/helpdesk_project_setting",
        :params => { :reply_box_form => '1',
                     :helpdesk_project_setting => { :reply_box_color => 'red; } body {' } }

    assert_nil HelpdeskProjectSetting.for_project(@project).reply_box_color
    assert flash[:error].present?
  end

  def test_the_settings_tab_renders_the_colour_fields
    log_user('jsmith', 'jsmith')

    get "/projects/#{@project.identifier}/settings/expert_helpdesk"
    assert_response :success
    assert_select 'input#hd_reply_box_color'
    assert_select 'input#hd_reply_hazard_color'
  end
end
