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

  def test_reextract_never_creates_an_entry
    RedmineExpertHelpdesk::KnowledgeExtractor.any_instance.expects(:extract).never
    assert_no_difference('HelpdeskKnowledgeEntry.count') do
      HelpdeskKnowledgeIngestJob.perform_now(@issue.id, :reextract => true)
    end
  end

  # --- selection ---------------------------------------------------------------

  def test_scope_picks_entries_at_another_level
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
    entry
    specific = entry(:issue_id => 1, :extract_detail => 'specific')
    assert_equal [specific.id], HelpdeskKnowledgeReextractJob.scope_for(@issue.project_id).pluck(:id)
  end

  def test_enqueue_fans_out_one_ingest_job_per_entry
    RedmineExpertHelpdesk::AiFeatures.stubs(:kb_ready?).returns(true)
    entry
    entry(:issue_id => 1)
    HelpdeskKnowledgeIngestJob.expects(:perform_later).with(@issue.id, :reextract => true)
    HelpdeskKnowledgeIngestJob.expects(:perform_later).with(1, :reextract => true)
    assert_equal 2, HelpdeskKnowledgeReextractJob.enqueue(@issue.project_id)
  end

  def test_enqueue_refuses_when_knowledge_base_not_ready
    RedmineExpertHelpdesk::AiFeatures.stubs(:kb_ready?).returns(false)
    entry
    HelpdeskKnowledgeIngestJob.expects(:perform_later).never
    assert_nil HelpdeskKnowledgeReextractJob.enqueue(@issue.project_id)
  end
end
