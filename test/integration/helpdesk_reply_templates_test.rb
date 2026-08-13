require File.expand_path('../../test_helper', __FILE__)

# Managing answer templates: per project (manage_helpdesk) and globally
# (administrators only), plus how they slot into the settings pages.
class HelpdeskReplyTemplatesTest < Redmine::IntegrationTest
  fixtures :projects, :users, :email_addresses, :members, :member_roles, :roles,
           :enabled_modules, :trackers, :projects_trackers, :issue_statuses,
           :enumerations, :issues

  def setup
    @project = Project.find(1)
    @project.enable_module!(:helpdesk)
    Role.find(1).add_permission!(:manage_helpdesk, :view_helpdesk_info)
    HelpdeskReplyTemplate.delete_all
  end

  def valid_params(overrides = {})
    { :helpdesk_reply_template =>
        { :name => 'Eingangsbestaetigung', :content => 'Danke fuer Ihre Anfrage.' }.merge(overrides) }
  end

  # --- Project templates -------------------------------------------------

  def test_project_crud_lifecycle
    log_user('jsmith', 'jsmith') # Manager in Projekt 1

    get "/projects/#{@project.identifier}/helpdesk_reply_templates/new"
    assert_response :success
    assert_select 'textarea#helpdesk_reply_template_content'
    assert_select 'code.hd-macro-chip' # Makro-Chips des gemeinsamen Partials

    assert_difference 'HelpdeskReplyTemplate.count', 1 do
      post "/projects/#{@project.identifier}/helpdesk_reply_templates", :params => valid_params
    end
    template = HelpdeskReplyTemplate.order(:id).last
    assert_redirected_to settings_project_path(@project, :tab => 'expert_helpdesk')
    assert_equal @project.id, template.project_id

    get "/projects/#{@project.identifier}/helpdesk_reply_templates/#{template.id}/edit"
    assert_response :success

    put "/projects/#{@project.identifier}/helpdesk_reply_templates/#{template.id}",
        :params => valid_params(:name => 'Umbenannt')
    assert_redirected_to settings_project_path(@project, :tab => 'expert_helpdesk')
    assert_equal 'Umbenannt', template.reload.name

    assert_difference 'HelpdeskReplyTemplate.count', -1 do
      delete "/projects/#{@project.identifier}/helpdesk_reply_templates/#{template.id}"
    end
  end

  def test_invalid_template_rerenders_the_form
    log_user('jsmith', 'jsmith')

    assert_no_difference 'HelpdeskReplyTemplate.count' do
      post "/projects/#{@project.identifier}/helpdesk_reply_templates",
           :params => valid_params(:name => '')
    end
    assert_response :success
    assert_select '#errorExplanation'
  end

  def test_project_routes_forbidden_without_manage_helpdesk
    Role.find(1).remove_permission!(:manage_helpdesk)
    log_user('jsmith', 'jsmith')

    get "/projects/#{@project.identifier}/helpdesk_reply_templates/new"
    assert_response :forbidden
  end

  # A project route must never reach a global template.
  def test_project_route_cannot_reach_a_global_template
    global = HelpdeskReplyTemplate.create!(:project_id => nil, :name => 'Global', :content => 'g')
    log_user('jsmith', 'jsmith')

    get "/projects/#{@project.identifier}/helpdesk_reply_templates/#{global.id}/edit"
    assert_response :missing
  end

  # --- Global templates ---------------------------------------------------

  def test_global_templates_require_admin
    log_user('jsmith', 'jsmith')
    get '/helpdesk_reply_templates'
    assert_response :forbidden
  end

  def test_global_crud_as_admin
    log_user('admin', 'admin')

    get '/helpdesk_reply_templates'
    assert_response :success

    assert_difference 'HelpdeskReplyTemplate.count', 1 do
      post '/helpdesk_reply_templates', :params => valid_params
    end
    template = HelpdeskReplyTemplate.order(:id).last
    assert_nil template.project_id
    assert_redirected_to '/settings/plugin/redmine_expert_helpdesk'

    get "/helpdesk_reply_templates/#{template.id}/edit"
    assert_response :success
  end

  # --- Integration into the settings pages --------------------------------

  def test_project_settings_tab_lists_the_templates
    HelpdeskReplyTemplate.create!(:project_id => @project.id, :name => 'Projektvorlage', :content => 'p')
    log_user('jsmith', 'jsmith')

    get settings_project_path(@project, :tab => 'expert_helpdesk')

    assert_response :success
    assert_select 'td', :text => /Projektvorlage/
  end

  def test_plugin_settings_page_links_to_the_global_templates
    log_user('admin', 'admin')

    get '/settings/plugin/redmine_expert_helpdesk'

    assert_response :success
    assert_select 'a[href=?]', '/helpdesk_reply_templates'
  end
end
