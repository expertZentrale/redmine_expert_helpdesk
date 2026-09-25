require File.expand_path('../../test_helper', __FILE__)

# Curation of knowledge-base entries outside the tab's controller: the ingest job must
# not overwrite a person's verdict on a re-close, the project reindex rebuilds from SQL,
# and removing a point never raises.
class HelpdeskKnowledgeCurationTest < ActiveSupport::TestCase
  fixtures :projects, :users, :trackers, :projects_trackers, :issue_statuses,
           :enumerations, :issues, :enabled_modules

  Result = RedmineExpertHelpdesk::KnowledgeExtractor::Result

  def setup
    @plugin_settings_snapshot = Setting.plugin_redmine_expert_helpdesk.dup
    Setting.plugin_redmine_expert_helpdesk =
      Setting.plugin_redmine_expert_helpdesk.merge('kb_enabled' => '1')
    HelpdeskKnowledgeEntry.delete_all
    @issue = Issue.find(8) # closed ticket of project 1
    assert @issue.closed?
    HelpdeskProjectSetting.where(:project_id => @issue.project_id).delete_all
    HelpdeskProjectSetting.create!(:project_id => @issue.project_id, :kb_ingest_mode => 'auto')

    store = stub(:configured? => true, :ensure_ready! => nil, :upsert => nil, :delete => nil, :reset! => nil)
    RedmineExpertHelpdesk::KnowledgeStore.stubs(:for).returns(store)
    @store = store
    RedmineExpertHelpdesk::AiClient.any_instance.stubs(:configured?).returns(true)
    RedmineExpertHelpdesk::AiClient.any_instance.stubs(:embed_configured?).returns(true)
    RedmineExpertHelpdesk::AiClient.any_instance.stubs(:embed).returns([0.1, 0.2])
    RedmineExpertHelpdesk::AiClient.any_instance.stubs(:embed_model).returns('test-embed')
  end

  def teardown
    Setting.plugin_redmine_expert_helpdesk = @plugin_settings_snapshot if @plugin_settings_snapshot
  end

  def curated_entry(status)
    HelpdeskKnowledgeEntry.create!(:project_id => @issue.project_id, :issue_id => @issue.id,
                                   :problem => 'korrigiert', :solution => 'richtig', :status => status,
                                   :updated_by_id => 2, :curated_at => Time.current)
  end

  def test_reclose_does_not_overwrite_curated_entry
    entry = curated_entry('approved')
    RedmineExpertHelpdesk::KnowledgeExtractor.any_instance.expects(:extract).never
    HelpdeskKnowledgeIngestJob.perform_now(@issue.id)
    assert_equal 'korrigiert', entry.reload.problem
  end

  def test_reclose_does_not_revive_rejected_entry
    entry = curated_entry('rejected')
    entry.update_columns(:curated_at => nil) # rejected alone is enough
    RedmineExpertHelpdesk::KnowledgeExtractor.any_instance.expects(:extract).never
    HelpdeskKnowledgeIngestJob.perform_now(@issue.id)
    assert_equal 'rejected', entry.reload.status
  end

  def test_forced_ingest_replaces_curated_entry_and_clears_curation
    entry = curated_entry('approved')
    RedmineExpertHelpdesk::KnowledgeExtractor.any_instance.stubs(:extract)
      .returns(Result.new(:problem => 'neu', :solution => 'neue Loesung', :has_solution => true, :usage => nil))
    @store.expects(:upsert).once
    HelpdeskKnowledgeIngestJob.perform_now(@issue.id, :force => true)
    entry.reload
    assert_equal 'neu', entry.problem
    assert_not entry.curated?
    assert_equal entry.id.to_s, entry.point_id
  end

  def test_reingest_without_solution_removes_stale_point
    entry = HelpdeskKnowledgeEntry.create!(:project_id => @issue.project_id, :issue_id => @issue.id,
                                           :problem => 'alt', :status => 'approved', :point_id => '1')
    RedmineExpertHelpdesk::KnowledgeExtractor.any_instance.stubs(:extract)
      .returns(Result.new(:problem => 'p', :solution => '', :has_solution => false, :usage => nil))
    @store.expects(:delete).with(@issue.project_id, entry.id)
    HelpdeskKnowledgeIngestJob.perform_now(@issue.id)
    entry.reload
    assert_equal 'skipped', entry.status
    assert_nil entry.point_id
  end

  def test_reindex_resets_project_and_embeds_only_approved
    approved = HelpdeskKnowledgeEntry.create!(:project_id => 1, :issue_id => 1, :problem => 'a', :status => 'approved')
    pending  = HelpdeskKnowledgeEntry.create!(:project_id => 1, :issue_id => 2, :problem => 'b', :status => 'pending',
                                              :point_id => '99')
    @store.expects(:reset!).with(1)
    @store.expects(:upsert).with(1, approved.id, [0.1, 0.2], anything).once
    assert_equal 1, HelpdeskKnowledgeReindexJob.rebuild(1)
    assert_equal approved.id.to_s, approved.reload.point_id
    assert_nil pending.reload.point_id
  end

  def test_unindex_swallows_store_errors
    entry = HelpdeskKnowledgeEntry.create!(:project_id => 1, :issue_id => 1, :problem => 'a',
                                           :status => 'approved', :point_id => '1')
    @store.stubs(:delete).raises(RedmineExpertHelpdesk::KnowledgeStore::StoreError, 'down')
    assert_equal false, HelpdeskKnowledgeEntry.unindex(entry)
    assert_equal '1', entry.reload.point_id
  end

  def test_rejected_is_a_valid_status_and_issue_must_match_project
    assert HelpdeskKnowledgeEntry.new(:project_id => 1, :issue_id => 1, :status => 'rejected').valid?
    foreign = HelpdeskKnowledgeEntry.new(:project_id => 1, :issue_id => 4, :status => 'approved')
    assert_not foreign.valid?
    assert foreign.errors[:issue_id].any?
  end
end
