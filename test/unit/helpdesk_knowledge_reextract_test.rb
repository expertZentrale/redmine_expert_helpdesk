require File.expand_path('../../test_helper', __FILE__)

# Re-extraction after a detail-level change: entries keep their status (an
# approved entry in 'manual' mode must stay searchable), a person's verdict is
# never touched, and the job only picks entries extracted at another level.
class HelpdeskKnowledgeReextractTest < ActiveSupport::TestCase
  fixtures :projects, :users, :trackers, :projects_trackers, :issue_statuses,
           :enumerations, :issues, :enabled_modules

  Result = RedmineExpertHelpdesk::KnowledgeExtractor::Result

  def setup
    @plugin_settings_snapshot = Setting.plugin_redmine_expert_helpdesk.dup
    Setting.plugin_redmine_expert_helpdesk =
      Setting.plugin_redmine_expert_helpdesk.merge('kb_enabled' => '1')
    HelpdeskKnowledgeEntry.delete_all
    @issue = Issue.find(8) # closed ticket of project 1
    HelpdeskProjectSetting.where(:project_id => @issue.project_id).delete_all
    @ps = HelpdeskProjectSetting.create!(:project_id => @issue.project_id, :kb_ingest_mode => 'manual',
                                         :kb_extract_detail => 'most_specific')

    @store = stub(:configured? => true, :ensure_ready! => nil, :upsert => nil, :delete => nil, :reset! => nil)
    RedmineExpertHelpdesk::KnowledgeStore.stubs(:for).returns(@store)
    RedmineExpertHelpdesk::AiClient.any_instance.stubs(:configured?).returns(true)
    RedmineExpertHelpdesk::AiClient.any_instance.stubs(:embed_configured?).returns(true)
    RedmineExpertHelpdesk::AiClient.any_instance.stubs(:embed).returns([0.1, 0.2])
    RedmineExpertHelpdesk::AiClient.any_instance.stubs(:embed_model).returns('test-embed')
  end

  def teardown
    Setting.plugin_redmine_expert_helpdesk = @plugin_settings_snapshot if @plugin_settings_snapshot
  end

  # Re-extraction only reaches closed tickets; most fixture issues are open.
  def close!(*ids)
    Issue.where(:id => ids).update_all(:status_id => 5)
  end

  def entry(attrs = {})
    HelpdeskKnowledgeEntry.create!({ :project_id => @issue.project_id, :issue_id => @issue.id,
                                     :problem => 'alt', :solution => 'alt', :status => 'approved' }.merge(attrs))
  end

  def stub_extract(has_solution: true)
    RedmineExpertHelpdesk::KnowledgeExtractor.any_instance.stubs(:extract)
      .returns(Result.new(:problem => 'Outlook 2016 0x800CCC0E', :solution => has_solution ? 'Profil neu' : '',
                          :has_solution => has_solution, :usage => nil, :detail => 'most_specific'))
  end

  # --- ingest job ------------------------------------------------------------

  def test_reextract_keeps_approved_status_in_manual_mode
    e = entry
    stub_extract
    @store.expects(:upsert).once
    HelpdeskKnowledgeIngestJob.perform_now(@issue.id, :reextract => true)
    e.reload
    assert_equal 'approved', e.status
    assert_equal 'Outlook 2016 0x800CCC0E', e.problem
    assert_equal 'most_specific', e.extract_detail
    assert_equal e.id.to_s, e.point_id
  end

  def test_plain_reingest_in_manual_mode_still_queues_for_review
    e = entry
    stub_extract
    HelpdeskKnowledgeIngestJob.perform_now(@issue.id)
    assert_equal 'pending', e.reload.status
  end

  def test_reextract_keeps_pending_status
    e = entry(:status => 'pending')
    stub_extract
    HelpdeskKnowledgeIngestJob.perform_now(@issue.id, :reextract => true)
    assert_equal 'pending', e.reload.status
  end

  def test_reextract_without_solution_skips_entry
    e = entry(:point_id => '1')
    stub_extract(:has_solution => false)
    HelpdeskKnowledgeIngestJob.perform_now(@issue.id, :reextract => true)
    assert_equal 'skipped', e.reload.status
  end

  def test_reextract_leaves_curated_and_rejected_entries_alone
    e = entry(:curated_at => Time.current, :updated_by_id => 2)
    RedmineExpertHelpdesk::KnowledgeExtractor.any_instance.expects(:extract).never
    HelpdeskKnowledgeIngestJob.perform_now(@issue.id, :reextract => true)
    assert_equal 'alt', e.reload.problem

    e.update_columns(:curated_at => nil, :status => 'rejected')
    HelpdeskKnowledgeIngestJob.perform_now(@issue.id, :reextract => true)
    assert_equal 'rejected', e.reload.status
  end

  # The tab still lists and counts entries of a project that stopped contributing;
  # the re-extraction it queues must then actually run.
  def test_reextract_runs_while_ingest_is_off
    @ps.update!(:kb_ingest_mode => 'off')
    e = entry
    stub_extract
    HelpdeskKnowledgeIngestJob.perform_now(@issue.id, :reextract => true)
    assert_equal 'Outlook 2016 0x800CCC0E', e.reload.problem
    assert_equal 'approved', e.status
  end

  def test_plain_ingest_still_respects_ingest_off
    @ps.update!(:kb_ingest_mode => 'off')
    entry
    RedmineExpertHelpdesk::KnowledgeExtractor.any_instance.expects(:extract).never
    HelpdeskKnowledgeIngestJob.perform_now(@issue.id)
  end

  # Double-submit / two admins: the same entry queued twice for one request
  # costs one AI call - the second job finds the row already claimed.
  def test_duplicate_reextract_job_calls_the_model_once
    e = entry
    e.update_columns(:updated_at => 1.hour.ago)
    at = 1.minute.ago
    RedmineExpertHelpdesk::KnowledgeExtractor.any_instance.expects(:extract).once
      .returns(Result.new(:problem => 'neu', :solution => 's', :has_solution => true, :usage => nil, :detail => 'most_specific'))
    2.times { HelpdeskKnowledgeIngestJob.perform_now(@issue.id, :reextract => true, :requested_at => at) }
    assert_equal 'neu', e.reload.problem
  end

  # Columns without fractional seconds: a claim in the request's second must
  # still block the duplicate.
  def test_claim_blocks_duplicate_within_the_same_second
    e = entry
    at = Time.current.change(:usec => 0)
    e.update_columns(:updated_at => at - 1.second)
    RedmineExpertHelpdesk::KnowledgeExtractor.any_instance.expects(:extract).once
      .returns(Result.new(:problem => 'neu', :solution => 's', :has_solution => true, :usage => nil, :detail => 'most_specific'))
    2.times { HelpdeskKnowledgeIngestJob.perform_now(@issue.id, :reextract => true, :requested_at => at) }
    assert_operator e.reload.updated_at, :>, at
  end

  # A person rejects the entry while the embedding call is in flight: the job
  # must not leave the stale machine text searchable.
  def test_reject_during_indexing_removes_the_point_again
    e = entry
    stub_extract
    @store.stubs(:upsert).with do |*|
      HelpdeskKnowledgeEntry.where(:id => e.id).update_all(:status => 'rejected', :curated_at => Time.current)
      true
    end
    HelpdeskKnowledgeEntry.expects(:unindex).with { |row| row.id == e.id }.returns(true)
    HelpdeskKnowledgeIngestJob.perform_now(@issue.id, :reextract => true)
  end

  # ... or edits it: the current text is embedded again, not the job's.
  def test_edit_during_indexing_reindexes_the_current_text
    e = entry
    stub_extract
    @store.stubs(:upsert).with do |*|
      HelpdeskKnowledgeEntry.where(:id => e.id).update_all(:problem => 'von Hand', :curated_at => Time.current)
      true
    end
    HelpdeskKnowledgeIngestJob.expects(:index_entry).with { |row| row.problem == 'von Hand' }.returns(true)
    HelpdeskKnowledgeIngestJob.perform_now(@issue.id, :reextract => true)
  end

  # An entry changed after the request (e.g. a later re-close) is left alone.
  def test_reextract_skips_entry_touched_after_the_request
    entry
    RedmineExpertHelpdesk::KnowledgeExtractor.any_instance.expects(:extract).never
    HelpdeskKnowledgeIngestJob.perform_now(@issue.id, :reextract => true, :requested_at => 1.hour.ago)
  end

  def test_reextract_never_creates_an_entry
    RedmineExpertHelpdesk::KnowledgeExtractor.any_instance.expects(:extract).never
    assert_no_difference('HelpdeskKnowledgeEntry.count') do
      HelpdeskKnowledgeIngestJob.perform_now(@issue.id, :reextract => true)
    end
  end

  # --- selection ---------------------------------------------------------------

  def test_scope_picks_entries_at_another_level
    close!(1, 2, 3, 7)
    legacy  = entry                                              # NULL = general
    general = entry(:issue_id => 1, :extract_detail => 'general')
    current = entry(:issue_id => 2, :extract_detail => 'most_specific')
    entry(:issue_id => 3, :extract_detail => 'specific', :curated_at => Time.current)
    entry(:issue_id => 7, :extract_detail => 'specific', :status => 'rejected')

    ids = HelpdeskKnowledgeReextractJob.scope_for(@issue.project_id).pluck(:id)
    assert_equal [legacy.id, general.id].sort, ids.sort

    all = HelpdeskKnowledgeReextractJob.scope_for(@issue.project_id, :all => true).pluck(:id)
    assert_equal [legacy.id, general.id, current.id].sort, all.sort
  end

  # At 'general' an entry from before the levels (NULL) is already current.
  def test_scope_treats_legacy_entries_as_general
    @ps.update!(:kb_extract_detail => 'general')
    close!(1)
    entry
    specific = entry(:issue_id => 1, :extract_detail => 'specific')
    assert_equal [specific.id], HelpdeskKnowledgeReextractJob.scope_for(@issue.project_id).pluck(:id)
  end

  def test_enqueue_fans_out_one_ingest_job_per_entry
    RedmineExpertHelpdesk::AiFeatures.stubs(:kb_ready?).returns(true)
    close!(1)
    entry
    entry(:issue_id => 1)
    at = 1.minute.ago
    HelpdeskKnowledgeIngestJob.expects(:perform_later).with(@issue.id, :reextract => true, :requested_at => at)
    HelpdeskKnowledgeIngestJob.expects(:perform_later).with(1, :reextract => true, :requested_at => at)
    assert_equal 2, HelpdeskKnowledgeReextractJob.enqueue(@issue.project_id, :requested_at => at)
  end

  # The ingest job skips reopened and deleted tickets; counting them kept the
  # stale count above zero forever.
  def test_scope_skips_reopened_and_deleted_tickets
    closed   = entry
    reopened = entry(:issue_id => 1) # fixture issue 1 is open
    orphan   = entry(:issue_id => 2)
    orphan.update_columns(:issue_id => 999_999)
    ids = HelpdeskKnowledgeReextractJob.scope_for(@issue.project_id, :all => true).pluck(:id)
    assert_equal [closed.id], ids
    assert_not_includes ids, reopened.id
  end

  def test_enqueue_refuses_when_knowledge_base_not_ready
    RedmineExpertHelpdesk::AiFeatures.stubs(:kb_ready?).returns(false)
    entry
    HelpdeskKnowledgeIngestJob.expects(:perform_later).never
    assert_nil HelpdeskKnowledgeReextractJob.enqueue(@issue.project_id)
  end
end
