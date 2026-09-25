require File.expand_path('../../test_helper', __FILE__)

# "Knowledge base" tab: three permission tiers (view/edit/manage_helpdesk_kb), every write
# goes through the SQL row and then re-embeds (approved) or removes the point (anything
# else) - the vector store itself is stubbed, it is not the subject here.
class HelpdeskKbEntriesTest < Redmine::IntegrationTest
  fixtures :projects, :users, :email_addresses, :members, :member_roles, :roles,
           :enabled_modules, :trackers, :projects_trackers, :issue_statuses,
           :enumerations, :issues, :journals, :journal_details

  PERMS = [:view_helpdesk_kb, :edit_helpdesk_kb, :manage_helpdesk_kb].freeze

  def setup
    # Plugin settings survive the transaction rollback; snapshot and restore.
    @plugin_settings_snapshot = Setting.plugin_redmine_expert_helpdesk.dup
    Setting.plugin_redmine_expert_helpdesk =
      Setting.plugin_redmine_expert_helpdesk.merge('kb_enabled' => '1')
    @project = Project.find(1)
    @project.enable_module!(:helpdesk)
    Role.find(1).remove_permission!(*PERMS)
    HelpdeskKnowledgeEntry.delete_all
    @entry = HelpdeskKnowledgeEntry.create!(:project_id => @project.id, :issue_id => 1,
                                            :problem => 'Drucker druckt nicht',
                                            :solution => 'Treiber neu installiert',
                                            :status => 'approved', :point_id => nil)
    RedmineExpertHelpdesk::AiFeatures.stubs(:kb_ready?).returns(true)
  end

  def teardown
    Setting.plugin_redmine_expert_helpdesk = @plugin_settings_snapshot if @plugin_settings_snapshot
  end

  def base
    "/projects/#{@project.identifier}/helpdesk_kb_entries"
  end

  def grant!(*perms)
    Role.find(1).add_permission!(*perms)
    log_user('jsmith', 'jsmith') # Manager in project 1
  end

  def test_tab_hidden_and_forbidden_without_permission
    log_user('jsmith', 'jsmith')
    get "/projects/#{@project.identifier}/issues"
    assert_select '#main-menu a.helpdesk-kb-entries', 0
    get base
    assert_response :forbidden
  end

  def test_tab_hidden_when_kb_disabled
    Setting.plugin_redmine_expert_helpdesk =
      Setting.plugin_redmine_expert_helpdesk.merge('kb_enabled' => '0')
    grant!(:view_helpdesk_kb)
    get "/projects/#{@project.identifier}/issues"
    assert_select '#main-menu a.helpdesk-kb-entries', 0
  end

  def test_viewer_sees_list_and_entry_but_no_write_actions
    grant!(:view_helpdesk_kb)
    get "/projects/#{@project.identifier}/issues"
    assert_select '#main-menu a.helpdesk-kb-entries'

    get base
    assert_response :success
    assert_select 'table.hd-kb-list tr.hd-kb-row', 1
    assert_select 'td.hd-kb-text', :text => /Drucker druckt nicht/
    assert_select 'a.icon-edit', 0
    assert_select 'a.icon-del', 0

    get "#{base}/#{@entry.id}"
    assert_response :success
    assert_select '.hd-kb-fulltext', :text => /Treiber neu installiert/

    get "#{base}/#{@entry.id}/edit"
    assert_response :forbidden
    put "#{base}/#{@entry.id}", :params => { :helpdesk_knowledge_entry => { :problem => 'x' } }
    assert_response :forbidden
    assert_equal 'Drucker druckt nicht', @entry.reload.problem
  end

  def test_filter_and_search
    HelpdeskKnowledgeEntry.create!(:project_id => @project.id, :issue_id => 2, :status => 'skipped',
                                   :problem => 'Mailversand', :solution => '')
    grant!(:view_helpdesk_kb)

    get base # default hides "skipped"
    assert_select 'tr.hd-kb-row', 1
    get base, :params => { :status => 'all' }
    assert_select 'tr.hd-kb-row', 2
    get base, :params => { :status => 'skipped' }
    assert_select 'tr.hd-kb-row.hd-kb-skipped', 1
    get base, :params => { :status => 'all', :q => 'TREIBER' }
    assert_select 'tr.hd-kb-row', 1
  end

  def test_editor_update_reembeds_and_records_curation
    grant!(:view_helpdesk_kb, :edit_helpdesk_kb)
    HelpdeskKnowledgeIngestJob.expects(:index_entry).with { |e| e.id == @entry.id && e.problem == 'Drucker offline' }.returns(true)

    put "#{base}/#{@entry.id}", :params => {
      :helpdesk_knowledge_entry => { :problem => 'Drucker offline', :solution => 'Kabel', :status => 'approved' }
    }
    assert_redirected_to "#{base}/#{@entry.id}"
    @entry.reload
    assert_equal 'Drucker offline', @entry.problem
    assert_equal 'Kabel', @entry.solution
    assert_equal 2, @entry.updated_by_id
    assert @entry.curated?
  end

  def test_update_warns_when_reembed_fails
    grant!(:view_helpdesk_kb, :edit_helpdesk_kb)
    HelpdeskKnowledgeIngestJob.stubs(:index_entry).returns(false)
    put "#{base}/#{@entry.id}", :params => { :helpdesk_knowledge_entry => { :problem => 'neu' } }
    assert_equal I18n.t(:text_helpdesk_kb_saved_not_indexed), flash[:warning]
    assert_equal 'neu', @entry.reload.problem
  end

  def test_reject_removes_point_and_sets_status
    @entry.update_columns(:point_id => @entry.id.to_s)
    grant!(:view_helpdesk_kb, :edit_helpdesk_kb)
    HelpdeskKnowledgeEntry.expects(:unindex).with { |e| e.id == @entry.id }.returns(true)
    HelpdeskKnowledgeIngestJob.expects(:index_entry).never

    post "#{base}/#{@entry.id}/reject"
    assert_equal 'rejected', @entry.reload.status
    assert @entry.curated?
  end

  def test_approve_pending_entry_indexes_it
    @entry.update_columns(:status => 'pending')
    grant!(:view_helpdesk_kb, :edit_helpdesk_kb)
    HelpdeskKnowledgeIngestJob.expects(:index_entry).returns(true)
    post "#{base}/#{@entry.id}/approve"
    assert_equal 'approved', @entry.reload.status
  end

  def test_create_manual_entry_and_foreign_issue_is_refused
    grant!(:view_helpdesk_kb, :edit_helpdesk_kb)
    HelpdeskKnowledgeIngestJob.expects(:index_entry).once.returns(true)

    # Issue 4 belongs to project 2 - must not enter project 1's knowledge base.
    assert_no_difference 'HelpdeskKnowledgeEntry.count' do
      post base, :params => { :helpdesk_knowledge_entry => { :issue_id => '4', :problem => 'p', :status => 'approved' } }
    end
    assert_response :success # form re-rendered
    # One entry per ticket.
    assert_no_difference 'HelpdeskKnowledgeEntry.count' do
      post base, :params => { :helpdesk_knowledge_entry => { :issue_id => '1', :problem => 'p', :status => 'approved' } }
    end

    assert_difference 'HelpdeskKnowledgeEntry.count', 1 do
      post base, :params => { :helpdesk_knowledge_entry => { :issue_id => '#2', :problem => 'VPN bricht ab',
                                                            :solution => 'MTU', :status => 'approved' } }
    end
    created = HelpdeskKnowledgeEntry.order(:id).last
    assert_equal 2, created.issue_id
    assert_equal @project.id, created.project_id
  end

  def test_entry_of_other_project_is_not_found
    other = HelpdeskKnowledgeEntry.create!(:project_id => 2, :issue_id => 4, :problem => 'x', :status => 'approved')
    grant!(:view_helpdesk_kb)
    get "#{base}/#{other.id}"
    assert_response :not_found
  end

  def test_destroy_keeps_row_when_point_cannot_be_removed
    @entry.update_columns(:point_id => @entry.id.to_s)
    grant!(:view_helpdesk_kb, :manage_helpdesk_kb)
    HelpdeskKnowledgeEntry.stubs(:unindex).returns(false)
    assert_no_difference 'HelpdeskKnowledgeEntry.count' do
      delete "#{base}/#{@entry.id}"
    end
    assert_redirected_to "#{base}/#{@entry.id}"
  end

  def test_destroy_and_reindex_need_manage_permission
    grant!(:view_helpdesk_kb, :edit_helpdesk_kb)
    delete "#{base}/#{@entry.id}"
    assert_response :forbidden
    post "#{base}/reindex"
    assert_response :forbidden

    Role.find(1).add_permission!(:manage_helpdesk_kb)
    @entry.update_columns(:point_id => @entry.id.to_s)
    HelpdeskKnowledgeEntry.expects(:unindex).returns(true)
    assert_difference 'HelpdeskKnowledgeEntry.count', -1 do
      delete "#{base}/#{@entry.id}"
    end

    HelpdeskKnowledgeReindexJob.expects(:perform_later).with(@project.id)
    post "#{base}/reindex"
    assert_redirected_to base
  end
end
