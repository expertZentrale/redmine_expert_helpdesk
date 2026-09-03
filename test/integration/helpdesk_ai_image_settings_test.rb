require File.expand_path('../../test_helper', __FILE__)

# Renders and saves the image size floor in the AI section of the project tab -
# exactly what an ERB syntax check cannot cover.
class HelpdeskAiImageSettingsTest < Redmine::IntegrationTest
  fixtures :projects, :users, :email_addresses, :members, :member_roles, :roles,
           :enabled_modules, :trackers, :projects_trackers, :issue_statuses,
           :enumerations, :issues

  def setup
    @project = Project.find(1)
    @project.enable_module!(:helpdesk)
    Role.find(1).add_permission!(:manage_helpdesk, :view_helpdesk_info)
  end

  # The whole AI section is gated on the central switch, so it has to be on here.
  def test_project_tab_renders_the_min_image_field
    log_user('jsmith', 'jsmith')

    with_plugin_setting('ai_enabled' => '1') do
      get settings_project_path(@project, :tab => 'expert_helpdesk')

      assert_response :success
      assert_select 'input#hd_ai_attach_images'
      assert_select 'input#hd_ai_min_image_kb'
    end
  end

  def test_saving_the_ai_form_stores_the_min_image_size
    log_user('jsmith', 'jsmith')

    put helpdesk_project_setting_path(:project_id => @project),
        :params => {
          :ai_form => '1',
          :helpdesk_project_setting => {
            :ai_summary_enabled => '1',
            :ai_attach_images => '1',
            :ai_min_image_kb => '40'
          }
        }
    assert_response :redirect

    ps = HelpdeskProjectSetting.for_project(@project)
    assert ps.ai_attach_images?
    assert_equal 40, ps.ai_min_image_kb
  end

  # 0 is a deliberate value ("send every image"), not a blank.
  def test_zero_is_stored_and_switches_the_floor_off
    log_user('jsmith', 'jsmith')

    put helpdesk_project_setting_path(:project_id => @project),
        :params => {
          :ai_form => '1',
          :helpdesk_project_setting => { :ai_attach_images => '1', :ai_min_image_kb => '0' }
        }
    assert_response :redirect

    ps = HelpdeskProjectSetting.for_project(@project)
    assert_equal 0, ps.ai_min_image_kb
    assert_equal 0, RedmineExpertHelpdesk::ImageRelevance.min_image_kb(ps)
  end

  def test_new_projects_default_to_the_shipped_floor
    ps = HelpdeskProjectSetting.for_project(Project.find(2))

    assert_equal RedmineExpertHelpdesk::ImageRelevance::DEFAULT_MIN_IMAGE_KB,
                 RedmineExpertHelpdesk::ImageRelevance.min_image_kb(ps)
  end

  def with_plugin_setting(hash)
    original = Setting.plugin_redmine_expert_helpdesk
    Setting.plugin_redmine_expert_helpdesk = original.merge(hash)
    yield
  ensure
    Setting.plugin_redmine_expert_helpdesk = original
  end
end
