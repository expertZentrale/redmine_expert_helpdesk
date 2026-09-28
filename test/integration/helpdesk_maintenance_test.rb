require File.expand_path('../../test_helper', __FILE__)

# The maintenance endpoint (status + switch) and its effect on both fetch paths.
class HelpdeskMaintenanceEndpointTest < Redmine::IntegrationTest
  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles,
           :enabled_modules

  KEY = 'maint-key'.freeze

  def setup
    HelpdeskFetchRun.delete_all
    @saved = Setting.plugin_redmine_expert_helpdesk
    Setting.plugin_redmine_expert_helpdesk = @saved.to_h.merge('fetch_api_key' => KEY, 'maintenance_mode' => '0')
  end

  def teardown
    Setting.plugin_redmine_expert_helpdesk = @saved
  end

  def json
    ActiveSupport::JSON.decode(response.body)
  end

  def test_requires_the_fetch_api_key
    get '/helpdesk/maintenance', :params => { :key => 'wrong' }
    assert_response 401
    post '/helpdesk/maintenance', :params => { :enabled => '1' }
    assert_response 401
    assert_not RedmineExpertHelpdesk::Maintenance.active?(:fresh => true)
  end

  def test_switch_on_and_off
    post '/helpdesk/maintenance', :params => { :key => KEY, :enabled => '1' }
    assert_response :success
    assert_equal true, json['maintenance']
    assert_equal true, json['safe_to_stop']
    assert RedmineExpertHelpdesk::Maintenance.active?(:fresh => true)

    post '/helpdesk/maintenance', :params => { :key => KEY, :enabled => '0' }
    assert_equal false, json['maintenance']
    assert_equal false, json['safe_to_stop']
  end

  def test_rejects_a_missing_enabled_value
    post '/helpdesk/maintenance', :params => { :key => KEY }
    assert_response 422
  end

  def test_status_lists_a_running_fetch
    RedmineExpertHelpdesk::Maintenance.set!(true)
    HelpdeskFetchRun.create!(:mailbox_address => 'support@example.com', :host => 'pod-a', :pid => 7,
                             :processed => 3, :started_at => Time.current, :heartbeat_at => Time.current)
    get '/helpdesk/maintenance', :params => { :key => KEY }
    assert_response :success
    assert_equal false, json['idle']
    assert_equal false, json['safe_to_stop']
    assert_equal [['support@example.com', 'pod-a', 3]],
                 json['running'].map { |r| [r['mailbox'], r['host'], r['processed']] }
  end

  def test_fetch_all_skips_every_mailbox_in_maintenance
    RedmineExpertHelpdesk::Maintenance.set!(true)
    RedmineExpertHelpdesk::MailProcessor.any_instance.expects(:process_all).never
    RedmineExpertHelpdesk::PhishingFeeds.expects(:run_if_stale).never
    get '/helpdesk/fetch_all', :params => { :key => KEY }
    assert_response :success
    assert_equal true, json['maintenance']
  end

  def test_project_fetch_button_is_blocked_in_maintenance
    RedmineExpertHelpdesk::Maintenance.set!(true)
    Project.find(1).enable_module!(:helpdesk)
    RedmineExpertHelpdesk::MailProcessor.any_instance.expects(:process_all).never
    log_user('admin', 'admin')
    post '/projects/ecookbook/helpdesk/fetch'
    assert_redirected_to '/projects/ecookbook/settings/expert_helpdesk'
    assert_equal I18n.t(:notice_helpdesk_maintenance_fetch_blocked), flash[:warning]
  end

  def test_admin_settings_page_shows_the_switch
    log_user('admin', 'admin')
    get '/settings/plugin/redmine_expert_helpdesk'
    assert_response :success
    assert_select '#hd-maintenance input#settings_maintenance_mode'
    assert_select '#hd-maintenance-idle'
  end
end
