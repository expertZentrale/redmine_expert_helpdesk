require File.expand_path('../../test_helper', __FILE__)

# GET /helpdesk/fetch_all as the cron job calls it: the key as a header (a query
# string ends up in proxy logs) and an immediate answer while another run holds
# the lock. The guards themselves are tested in test/unit/fetch_all_test.rb.
class HelpdeskFetchAllEndpointTest < Redmine::IntegrationTest
  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles,
           :enabled_modules

  KEY = 'fetch-key'.freeze

  def setup
    @saved = Setting.plugin_redmine_expert_helpdesk
    Setting.plugin_redmine_expert_helpdesk = @saved.to_h.merge('fetch_api_key' => KEY, 'maintenance_mode' => '0')
  end

  def teardown
    Setting.plugin_redmine_expert_helpdesk = @saved
  end

  def json
    ActiveSupport::JSON.decode(response.body)
  end

  def test_accepts_the_key_as_bearer_header
    RedmineExpertHelpdesk::FetchAll.expects(:run).returns('support@example.com' => { :processed => 2 })

    get '/helpdesk/fetch_all', :headers => { 'Authorization' => "Bearer #{KEY}" }
    assert_response :success
    assert_equal 2, json['mailboxes']['support@example.com']['processed']
  end

  # The scheme name is case-insensitive (RFC 9110).
  def test_accepts_the_bearer_scheme_in_any_case
    RedmineExpertHelpdesk::FetchAll.expects(:run).twice.returns({})

    get '/helpdesk/fetch_all', :headers => { 'Authorization' => "bearer #{KEY}" }
    assert_response :success
    get '/helpdesk/fetch_all', :headers => { 'Authorization' => "BEARER  #{KEY}" }
    assert_response :success
  end

  def test_still_accepts_the_key_as_query_parameter
    RedmineExpertHelpdesk::FetchAll.expects(:run).returns({})

    get '/helpdesk/fetch_all', :params => { :key => KEY }
    assert_response :success
  end

  def test_rejects_a_wrong_key_in_either_place
    RedmineExpertHelpdesk::FetchAll.expects(:run).never

    get '/helpdesk/fetch_all', :headers => { 'Authorization' => 'Bearer wrong' }
    assert_response 401
    get '/helpdesk/fetch_all', :params => { :key => 'wrong' }
    assert_response 401
  end

  def test_answers_at_once_while_another_run_holds_the_lock
    RedmineExpertHelpdesk::FetchAll.expects(:run).returns(nil)

    get '/helpdesk/fetch_all', :headers => { 'Authorization' => "Bearer #{KEY}" }
    assert_response :success
    assert_equal true, json['skipped']
    assert_equal 'already_running', json['reason']
    assert_equal({}, json['mailboxes'])
  end

  def test_maintenance_and_sla_check_accept_the_bearer_header_too
    get '/helpdesk/maintenance', :headers => { 'Authorization' => "Bearer #{KEY}" }
    assert_response :success
    assert_equal false, json['maintenance']

    Setting.plugin_redmine_expert_helpdesk = Setting.plugin_redmine_expert_helpdesk.to_h.merge('sla_api_key' => 'sla-key')
    RedmineExpertHelpdesk::SlaBreachCheck.expects(:run_if_due).returns(0)
    get '/helpdesk/sla_check', :headers => { 'Authorization' => 'Bearer sla-key' }
    assert_response :success
  end
end
