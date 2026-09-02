require File.expand_path('../../test_helper', __FILE__)

# Renders and saves the follow-up form in the project tab and checks the admin
# page - exactly what an ERB syntax check cannot cover.
class HelpdeskInfoRequestSettingsTest < Redmine::IntegrationTest
  fixtures :projects, :users, :email_addresses, :members, :member_roles, :roles,
           :enabled_modules, :trackers, :projects_trackers, :issue_statuses,
           :enumerations, :issues

  def setup
    @project = Project.find(1)
    @project.enable_module!(:helpdesk)
    Role.find(1).add_permission!(:manage_helpdesk, :view_helpdesk_info)
  end

  def settings_tab
    get settings_project_path(@project, :tab => 'expert_helpdesk')
  end

  def test_project_tab_renders_the_info_request_form
    log_user('jsmith', 'jsmith')
    settings_tab

    assert_response :success
    assert_select 'select#hd_ir_mode' do
      HelpdeskProjectSetting::INFO_REQUEST_MODES.each do |mode|
        assert_select 'option[value=?]', mode
      end
    end
    assert_select 'div#hd_ir_heuristic input#hd_ir_min_chars'
    assert_select 'div#hd_ir_heuristic input#hd_ir_min_att_kb'
    assert_select 'div#hd_ir_heuristic textarea#hd_ir_keywords'
    assert_select 'div#hd_ir_ai textarea#hd_ir_prompt'
    assert_select 'textarea#hd_ir_body'
    assert_select 'select#hd_ir_status option[value=""]'
    assert_select 'select#hd_ir_note_vis' do
      assert_select 'option[value=?]', 'public'
      assert_select 'option[value=?]', 'private'
    end
  end

  # The hint appears exactly when the central switch is off.
  def test_tab_warns_when_globally_disabled
    log_user('jsmith', 'jsmith')

    with_plugin_setting('info_request_enabled' => '0') do
      settings_tab
      assert_select 'em.info', :text => I18n.t(:text_helpdesk_info_request_globally_off)
    end

    with_plugin_setting('info_request_enabled' => '1') do
      settings_tab
      assert_select 'em.info', :text => I18n.t(:text_helpdesk_info_request_globally_off), :count => 0
    end
  end

  def test_saving_the_form_stores_the_settings
    log_user('jsmith', 'jsmith')

    put helpdesk_project_setting_path(:project_id => @project),
        :params => {
          :info_request_form => '1',
          :helpdesk_project_setting => {
            :info_request_mode => 'heuristic',
            :info_request_min_chars => '150',
            :info_request_min_words => '12',
            :info_request_require_attachment => '1',
            :info_request_min_attachment_kb => '40',
            :info_request_keywords => "Drucker\nSAP",
            :info_request_threshold => '2',
            :info_request_ai_prompt_mode => 'extend',
            :info_request_ai_prompt => 'Projekt-Prompt',
            :info_request_subject => 'Rueckfrage',
            :info_request_body => 'Bitte ergaenzen: {{missing_info}}',
            :info_request_note_visibility => 'private',
            :info_request_status_id => '2'
          }
        }
    assert_response :redirect

    ps = HelpdeskProjectSetting.for_project(@project)
    assert_equal 'heuristic', ps.info_request_mode
    assert_equal 150, ps.info_request_min_chars
    assert_equal 12,  ps.info_request_min_words
    assert ps.info_request_require_attachment?
    assert_equal 40, ps.info_request_min_attachment_kb
    assert_equal %w[drucker sap], ps.info_request_keyword_list
    assert_equal 2, ps.info_request_threshold
    assert_equal 'extend', ps.info_request_ai_prompt_mode
    assert_equal 2, ps.info_request_status_id
    assert ps.info_request_note_private?
  end

  # An unknown value must not overwrite the stored visibility.
  def test_invalid_note_visibility_is_ignored
    log_user('jsmith', 'jsmith')
    HelpdeskProjectSetting.for_project(@project).update!(:info_request_note_visibility => 'private')

    put helpdesk_project_setting_path(:project_id => @project),
        :params => { :info_request_form => '1',
                     :helpdesk_project_setting => { :info_request_note_visibility => 'bogus' } }

    assert HelpdeskProjectSetting.for_project(@project).reload.info_request_note_private?
  end

  # An unknown mode must not overwrite the stored value.
  def test_invalid_mode_is_ignored
    log_user('jsmith', 'jsmith')
    HelpdeskProjectSetting.for_project(@project).update!(:info_request_mode => 'heuristic')

    put helpdesk_project_setting_path(:project_id => @project),
        :params => { :info_request_form => '1',
                     :helpdesk_project_setting => { :info_request_mode => 'bogus' } }

    assert_equal 'heuristic', HelpdeskProjectSetting.for_project(@project).reload.info_request_mode
  end

  # A crafted non-numeric id type-casts to 0, which is NOT blank in Rails, so it
  # would pass every guard and be written to the issue with validate => false.
  def test_non_numeric_status_id_is_rejected
    log_user('jsmith', 'jsmith')

    put helpdesk_project_setting_path(:project_id => @project),
        :params => { :info_request_form => '1',
                     :helpdesk_project_setting => { :info_request_mode => 'heuristic',
                                                    :info_request_status_id => 'bogus' } }

    assert_nil HelpdeskProjectSetting.for_project(@project).info_request_status_id
  end

  def test_unknown_status_id_is_rejected
    log_user('jsmith', 'jsmith')

    put helpdesk_project_setting_path(:project_id => @project),
        :params => { :info_request_form => '1',
                     :helpdesk_project_setting => { :info_request_mode => 'heuristic',
                                                    :info_request_status_id => '999999' } }

    assert_nil HelpdeskProjectSetting.for_project(@project).info_request_status_id
  end

  # Closing a ticket counts as reaction AND solution for the SLA, so an automatic
  # follow-up must never be able to do it - not even by configuration.
  def test_closed_status_is_rejected
    log_user('jsmith', 'jsmith')
    closed = IssueStatus.where(:is_closed => true).first

    put helpdesk_project_setting_path(:project_id => @project),
        :params => { :info_request_form => '1',
                     :helpdesk_project_setting => { :info_request_mode => 'heuristic',
                                                    :info_request_status_id => closed.id.to_s } }

    assert_nil HelpdeskProjectSetting.for_project(@project).info_request_status_id
  end

  def test_status_select_offers_only_open_statuses
    log_user('jsmith', 'jsmith')
    settings_tab

    IssueStatus.where(:is_closed => true).each do |st|
      assert_select "select#hd_ir_status option[value=?]", st.id.to_s, :count => 0
    end
    open_status = IssueStatus.where(:is_closed => false).first
    assert_select "select#hd_ir_status option[value=?]", open_status.id.to_s
  end

  # A threshold of 0 would fire on every mail - the controller keeps it at 1.
  def test_threshold_zero_is_clamped
    log_user('jsmith', 'jsmith')
    put helpdesk_project_setting_path(:project_id => @project),
        :params => { :info_request_form => '1',
                     :helpdesk_project_setting => { :info_request_mode => 'heuristic',
                                                    :info_request_threshold => '0' } }

    assert_equal 1, HelpdeskProjectSetting.for_project(@project).info_request_threshold
  end

  def test_admin_settings_page_renders_the_section
    log_user('admin', 'admin')
    get plugin_settings_path(:id => 'redmine_expert_helpdesk')

    assert_response :success
    assert_select 'input#settings_info_request_enabled'
    assert_select 'textarea#settings_info_request_body'
    assert_select 'textarea#settings_info_request_ai_prompt'
  end

  private

  def with_plugin_setting(hash)
    original = Setting.plugin_redmine_expert_helpdesk
    Setting.plugin_redmine_expert_helpdesk = original.merge(hash)
    yield
  ensure
    Setting.plugin_redmine_expert_helpdesk = original
  end
end
