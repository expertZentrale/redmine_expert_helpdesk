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

  def test_reindex_does_not_reset_without_embeddings
    RedmineExpertHelpdesk::AiClient.any_instance.stubs(:embed_configured?).returns(false)
    entry = HelpdeskKnowledgeEntry.create!(:project_id => 1, :issue_id => 1, :problem => 'a',
                                           :status => 'approved', :point_id => '1')
    @store.expects(:reset!).never
    assert_nil HelpdeskKnowledgeReindexJob.rebuild(1)
    assert_equal '1', entry.reload.point_id
  end

  def test_reindex_leaves_failed_rows_unindexed
    entry = HelpdeskKnowledgeEntry.create!(:project_id => 1, :issue_id => 1, :problem => 'a',
                                           :status => 'approved', :point_id => '1')
    @store.stubs(:upsert).raises(RedmineExpertHelpdesk::KnowledgeStore::StoreError, 'dim')
    assert_equal 0, HelpdeskKnowledgeReindexJob.rebuild(1)
    assert_nil entry.reload.point_id
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
  # --- sync_vector! against a write that overlaps its embedding call ----------

  # Runs `during` once, the moment the first upsert reaches the store, i.e. after
  # the embedding call and before the post-upsert check.
  def while_embedding(&during)
    RedmineExpertHelpdesk::AiFeatures.stubs(:kb_ready?).returns(true)
    fired = false
    @store.stubs(:upsert).with do |*_args|
      unless fired
        fired = true
        during.call
      end
      true
    end
  end

  def test_sync_vector_rejected_during_embedding_is_removed_again
    entry = curated_entry('approved')
    while_embedding { HelpdeskKnowledgeEntry.where(:id => entry.id).update_all(:status => 'rejected') }
    @store.expects(:delete).with(entry.project_id, entry.id).once

    assert_equal :removed, entry.sync_vector!
    assert_equal 'rejected', entry.status, 'reloaded: the result describes the stored row'
    assert_nil entry.point_id
  end

  def test_sync_vector_edited_during_embedding_reembeds_the_newer_text
    RedmineExpertHelpdesk::AiFeatures.stubs(:kb_ready?).returns(true)
    entry = curated_entry('approved')
    payloads = []
    @store.stubs(:upsert).with do |*args|
      HelpdeskKnowledgeEntry.where(:id => entry.id).update_all(:problem => 'neuer') if payloads.empty?
      payloads << args.last['problem']
      true
    end

    assert_equal :indexed, entry.sync_vector!
    assert_equal %w[korrigiert neuer], payloads
    assert_equal 'neuer', entry.problem
  end

  def test_sync_vector_deleted_during_embedding_removes_the_point
    entry = curated_entry('approved')
    while_embedding { HelpdeskKnowledgeEntry.where(:id => entry.id).delete_all }
    @store.expects(:delete).with(entry.project_id, entry.id).once

    assert_equal :removed, entry.sync_vector!
  end

  def test_sync_vector_reports_failed_unindex_after_overlapping_reject
    entry = curated_entry('approved')
    while_embedding { HelpdeskKnowledgeEntry.where(:id => entry.id).update_all(:status => 'rejected') }
    @store.stubs(:delete).raises(StandardError, 'store down')

    assert_equal :unindex_failed, entry.sync_vector!
  end
  # --- Overlapping requests: the last sync acts on the last write -------------

  # An older rejection whose sync runs after a newer approval finished must not
  # delete the newer vector: it acts on the row as it is now (approved).
  def test_late_sync_of_an_older_rejection_keeps_the_newer_approval
    RedmineExpertHelpdesk::AiFeatures.stubs(:kb_ready?).returns(true)
    entry = curated_entry('rejected') # this request's copy
    HelpdeskKnowledgeEntry.where(:id => entry.id).update_all(:status => 'approved', :point_id => entry.id.to_s)
    @store.expects(:delete).never
    @store.expects(:upsert).once

    assert_equal :indexed, entry.sync_vector!
    assert_equal 'approved', entry.status
  end

  # An approval whose sync runs after a delete finished must not re-embed the
  # entry: the delete removed the point before the row, nothing would remove it.
  def test_late_sync_after_a_delete_does_not_reembed
    RedmineExpertHelpdesk::AiFeatures.stubs(:kb_ready?).returns(true)
    entry = curated_entry('approved')
    HelpdeskKnowledgeEntry.where(:id => entry.id).delete_all
    @store.expects(:upsert).never

    assert_equal :removed, entry.sync_vector!
  end

  def test_destroy_with_vector_removes_point_then_row
    entry = curated_entry('approved')
    entry.update_columns(:point_id => entry.id.to_s)
    @store.expects(:delete).with(entry.project_id, entry.id).once

    assert entry.destroy_with_vector!
    assert_not HelpdeskKnowledgeEntry.exists?(entry.id)
  end

  def test_destroy_with_vector_keeps_row_when_point_removal_fails
    entry = curated_entry('approved')
    entry.update_columns(:point_id => entry.id.to_s)
    @store.stubs(:delete).raises(StandardError, 'store down')

    assert_not entry.destroy_with_vector!
    assert HelpdeskKnowledgeEntry.exists?(entry.id)
  end

  # What serializes the two: both take the row lock before touching the store.
  def test_sync_and_destroy_take_the_row_lock
    skip 'adapter has no row locks' unless HelpdeskKnowledgeEntry.connection.adapter_name =~ /mysql|postg/i

    RedmineExpertHelpdesk::AiFeatures.stubs(:kb_ready?).returns(true)
    entry = curated_entry('approved')
    sql = []
    callback = ->(*, payload) { sql << payload[:sql] }
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      entry.sync_vector!
      entry.destroy_with_vector!
    end
    locks = sql.grep(/helpdesk_knowledge_entries.*FOR UPDATE/m)
    assert_equal 2, locks.size, sql.join("\n")
  end
  # The rebuild embeds outside any request; a delete during its embedding call
  # must not leave an orphan point behind.
  def test_reindex_removes_point_of_an_entry_deleted_during_embedding
    RedmineExpertHelpdesk::AiFeatures.stubs(:kb_ready?).returns(true)
    entry = HelpdeskKnowledgeEntry.create!(:project_id => 1, :issue_id => 1, :problem => 'a', :status => 'approved')
    while_embedding { HelpdeskKnowledgeEntry.where(:id => entry.id).delete_all }
    @store.expects(:delete).with(1, entry.id).once

    assert_equal 0, HelpdeskKnowledgeReindexJob.rebuild(1)
  end
end
