require File.expand_path('../../test_helper', __FILE__)

# Background run bookkeeping for the legacy import / attachment repair: what
# counts as a live run (and so blocks a second one), progress throttling, and
# the job's transitions. The test DB has no redmine_contacts tables, so the
# repair runs against an empty legacy dataset.
class HelpdeskLegacyImportRunTest < ActiveSupport::TestCase
  fixtures :users

  def setup
    HelpdeskLegacyImportRun.delete_all
  end

  def run!(attrs = {})
    HelpdeskLegacyImportRun.create!({ :kind => 'fix_attachments', :status => 'queued' }.merge(attrs))
  end

  def test_current_returns_a_live_run_only
    run!(:status => 'done')
    assert_nil HelpdeskLegacyImportRun.current

    live = run!(:status => 'running')
    assert_equal live, HelpdeskLegacyImportRun.current
  end

  def test_a_run_without_heartbeat_is_stale_and_no_longer_current
    run = run!(:status => 'running')
    run.update_columns(:updated_at => 2.hours.ago)
    run.reload

    assert run.stale?
    assert_not run.active?
    assert_nil HelpdeskLegacyImportRun.current
  end

  def test_progress_is_throttled_within_a_phase
    run = run!(:status => 'running')
    run.progress!('issues', 1, 1000)
    run.update_columns(:progress_done => 1)

    run.progress!('issues', 2, 1000)
    assert_equal 1, run.reload.progress_done, 'rows between checkpoints must not hit the DB'

    run.progress!('issues', 100, 1000)
    assert_equal 100, run.reload.progress_done
    run.progress!('issues', 1000, 1000)
    assert_equal 1000, run.reload.progress_done, 'the last row is always written'
  end

  def test_project_ids_round_trip
    run = run!(:kind => 'import')
    run.project_id_list = ['5', 'none']
    run.save!
    assert_equal %w[5 none], run.reload.project_id_list

    run.project_id_list = nil
    assert_nil run.project_id_list
  end

  def test_job_finishes_the_run_with_its_counters
    run = run!
    HelpdeskLegacyImportJob.perform_now(run.id)
    run.reload

    assert_equal 'done', run.status
    assert run.started_at
    assert run.finished_at
    assert_equal 0, run.result_hash[:attachments_fixed]
  end

  def test_job_records_failure
    run = run!
    RedmineExpertHelpdesk::LegacyContactsImport.any_instance.stubs(:fix_attachments).raises(StandardError, 'boom')
    HelpdeskLegacyImportJob.perform_now(run.id)
    run.reload

    assert_equal 'failed', run.status
    assert_equal 'boom', run.error_message
  end

  def test_job_ignores_a_run_that_is_not_queued
    run = run!(:status => 'done')
    RedmineExpertHelpdesk::LegacyContactsImport.any_instance.expects(:fix_attachments).never
    HelpdeskLegacyImportJob.perform_now(run.id)
  end
end
