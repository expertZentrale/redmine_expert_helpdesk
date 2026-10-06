require File.expand_path('../../test_helper', __FILE__)

# Detail level and extraction prompt of the knowledge base: the project form
# (rendered and saved), the REST endpoint and the central admin page.
class HelpdeskKbExtractSettingsTest < Redmine::IntegrationTest
  fixtures :projects, :users, :email_addresses, :members, :member_roles, :roles,
           :enabled_modules, :trackers, :projects_trackers, :issue_statuses,
           :enumerations, :issues

  def setup
    @plugin_settings_snapshot = Setting.plugin_redmine_expert_helpdesk.dup
    Setting.plugin_redmine_expert_helpdesk =
      Setting.plugin_redmine_expert_helpdesk.merge('kb_enabled' => '1', 'kb_extract_detail' => 'specific')
    @project = Project.find(1)
    @project.enable_module!(:helpdesk)
    Role.find(1).add_permission!(:manage_helpdesk, :view_helpdesk_info)
    HelpdeskProjectSetting.where(:project_id => @project.id).delete_all
  end

  def teardown
    Setting.plugin_redmine_expert_helpdesk = @plugin_settings_snapshot if @plugin_settings_snapshot
  end

  def save(attrs)
    put helpdesk_project_setting_path(:project_id => @project),
        :params => { :kb_form => '1', :helpdesk_project_setting => { :kb_ingest_mode => 'auto' }.merge(attrs) }
    assert_response :redirect
    HelpdeskProjectSetting.for_project(@project)
  end

  def test_project_tab_renders_level_mode_and_prompt
    log_user('jsmith', 'jsmith')
    get settings_project_path(@project, :tab => 'expert_helpdesk')

    assert_response :success
    assert_select 'select#hd_kb_extract_detail' do
      # Blank = central level, named so the agent sees what "inherit" means.
      assert_select 'option[value=""]', :text => /Spezifisch|Specific/
      RedmineExpertHelpdesk::KnowledgeExtractor::DETAIL_LEVELS.each { |d| assert_select 'option[value=?]', d }
    end
    assert_select 'select#hd_kb_extract_prompt_mode'
    assert_select 'textarea#hd_kb_extract_prompt[placeholder*=?]', 'Fehlercode'
    # One prompt per option so the placeholder can follow the select.
    prompts = JSON.parse(css_select('textarea#hd_kb_extract_prompt').first['data-prompts'])
    assert_equal ['', *RedmineExpertHelpdesk::KnowledgeExtractor::DETAIL_LEVELS].sort, prompts.keys.sort
    assert_includes prompts['most_specific'], 'Verallgemeinere'
    assert_equal prompts['specific'], prompts['']
  end

  def test_saving_stores_level_mode_and_prompt
    log_user('jsmith', 'jsmith')
    ps = save(:kb_extract_detail => 'most_specific', :kb_extract_prompt_mode => 'extend',
              :kb_extract_prompt => ' Nenne die Filiale. ')
    assert_equal 'most_specific', ps.kb_extract_detail
    assert_equal 'extend', ps.kb_extract_prompt_mode
    assert_equal 'Nenne die Filiale.', ps.kb_extract_prompt

    # Blank level = back to the central one.
    ps = save(:kb_extract_detail => '', :kb_extract_prompt_mode => 'inherit', :kb_extract_prompt => '')
    assert_nil ps.kb_extract_detail
    assert_nil ps.kb_extract_prompt
    assert_equal 'specific', ps.effective_kb_extract_detail
  end

  def test_unknown_values_are_ignored
    log_user('jsmith', 'jsmith')
    save(:kb_extract_detail => 'specific', :kb_extract_prompt_mode => 'extend')
    ps = save(:kb_extract_detail => 'bogus', :kb_extract_prompt_mode => 'bogus')
    assert_equal 'specific', ps.kb_extract_detail
    assert_equal 'extend', ps.kb_extract_prompt_mode
  end

  def test_rest_api_reads_and_writes_the_fields
    with_settings :rest_api_enabled => '1' do
      key = User.find(2).api_key
      put "/projects/#{@project.identifier}/helpdesk/settings.json",
          :params => { :helpdesk_project_setting => { :kb_extract_detail => 'most_specific',
                                                      :kb_extract_prompt_mode => 'override',
                                                      :kb_extract_prompt => 'EIGEN' } }.to_json,
          :headers => { 'CONTENT_TYPE' => 'application/json', 'X-Redmine-API-Key' => key }
      assert_response :success

      get "/projects/#{@project.identifier}/helpdesk/settings.json", :headers => { 'X-Redmine-API-Key' => key }
      json = ActiveSupport::JSON.decode(response.body)['helpdesk_project_setting']
      assert_equal 'most_specific', json['kb_extract_detail']
      assert_equal 'override', json['kb_extract_prompt_mode']
      assert_equal 'most_specific', json['effective_kb_extract_detail']

      put "/projects/#{@project.identifier}/helpdesk/settings.json",
          :params => { :helpdesk_project_setting => { :kb_extract_detail => 'bogus' } }.to_json,
          :headers => { 'CONTENT_TYPE' => 'application/json', 'X-Redmine-API-Key' => key }
      assert_response :unprocessable_entity
    end
  end

  def test_admin_page_shows_level_and_empty_prompt_for_seeded_default
    Setting.plugin_redmine_expert_helpdesk = Setting.plugin_redmine_expert_helpdesk.merge(
      'kb_extract_prompt' => RedmineExpertHelpdesk::KnowledgeExtractor::DEFAULT_PROMPT
    )
    log_user('admin', 'admin')
    get plugin_settings_path(:id => 'redmine_expert_helpdesk')

    assert_response :success
    assert_select 'select#hd_kb_extract_detail option[selected][value=?]', 'specific'
    # The seeded old default is not the admin's own text: the field is empty and
    # the selected level's prompt shows as placeholder.
    assert_select 'textarea#hd_kb_extract_prompt', :text => ''
    assert_select 'textarea#hd_kb_extract_prompt[placeholder*=?]', 'Fehlercode'
  end
end
