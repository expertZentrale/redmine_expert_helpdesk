require File.expand_path('../../test_helper', __FILE__)

# Legacy import / attachment repair from the plugin settings: the POST only
# queues a background run and redirects to its status page, which polls JSON.
class HelpdeskLegacyImportTest < Redmine::IntegrationTest
  fixtures :projects, :users, :email_addresses, :issues, :attachments

  def setup
    HelpdeskLegacyImportRun.delete_all
    # One attachment still hanging off a redmine_contacts_helpdesk ticket
    Attachment.find(1).update_columns(:container_type => 'HelpdeskTicket')
    # Redmine's test env runs jobs :inline, which would finish the run inside
    # the POST and hide exactly what is under test here.
    @adapter = ActiveJob::Base.queue_adapter
    ActiveJob::Base.queue_adapter = :test
  end

  def teardown
    ActiveJob::Base.queue_adapter = @adapter
  end

  def enqueued
    ActiveJob::Base.queue_adapter.enqueued_jobs.select { |j| j[:job] == HelpdeskLegacyImportJob }
  end

  def status_json(run)
    get "/helpdesk/legacy_import/runs/#{run.id}/status"
    assert_response :success
    ActiveSupport::JSON.decode(response.body)
  end

  def test_fix_attachments_queues_a_run_and_redirects_to_its_status
    log_user('admin', 'admin')
    assert_difference 'HelpdeskLegacyImportRun.count', 1 do
      post '/helpdesk/legacy_fix_attachments'
    end
    run = HelpdeskLegacyImportRun.order(:id).last
    assert_equal [run.id], enqueued.map { |j| j[:args].first }
    assert_redirected_to "/helpdesk/legacy_import/runs/#{run.id}"
    assert_equal 'queued', run.status
    assert_equal User.find_by_login('admin'), run.user

    get "/helpdesk/legacy_import/runs/#{run.id}"
    assert_response :success
    assert_select '#hd-legacy-run[data-url=?]', "/helpdesk/legacy_import/runs/#{run.id}/status"

    # Polled with the session cookie only, as the status page's fetch() does
    body = status_json(run)
    assert_equal 'queued', body['status']
    assert_equal false, body['finished']

    HelpdeskLegacyImportJob.perform_now(run.id)
    body = status_json(run)
    assert_equal 'done', body['status']
    assert_equal true, body['finished']
    assert body['message'].present?
  end

  def test_a_live_run_blocks_a_second_one
    live = HelpdeskLegacyImportRun.create!(:kind => 'import', :status => 'running')
    log_user('admin', 'admin')

    assert_no_difference 'HelpdeskLegacyImportRun.count' do
      post '/helpdesk/legacy_fix_attachments'
    end
    assert_empty enqueued
    assert_redirected_to "/helpdesk/legacy_import/runs/#{live.id}"
  end

  def test_status_is_admin_only
    run = HelpdeskLegacyImportRun.create!(:kind => 'fix_attachments', :status => 'done')
    log_user('jsmith', 'jsmith')
    get "/helpdesk/legacy_import/runs/#{run.id}/status"
    assert_response 403
  end

  def test_unknown_run_is_404
    log_user('admin', 'admin')
    get '/helpdesk/legacy_import/runs/999999/status'
    assert_response 404
  end
end
