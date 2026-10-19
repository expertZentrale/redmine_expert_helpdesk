require File.expand_path('../../test_helper', __FILE__)

# REST API of the knowledge base: same three permission tiers as the tab, every
# write reports how the vector store took it (vector_sync). The store itself is
# stubbed, as in helpdesk_kb_entries_test.rb.
class HelpdeskKbEntriesApiTest < Redmine::IntegrationTest
  fixtures :projects, :users, :email_addresses, :members, :member_roles, :roles,
           :enabled_modules, :trackers, :projects_trackers, :issue_statuses,
           :enumerations, :issues, :journals, :journal_details

  PERMS = [:view_helpdesk_kb, :edit_helpdesk_kb, :manage_helpdesk_kb].freeze

  def setup
    Setting.rest_api_enabled = '1'
    @project = Project.find(1)
    @project.enable_module!(:helpdesk)
    Role.find(1).remove_permission!(*PERMS)
    HelpdeskKnowledgeEntry.delete_all
    @entry = HelpdeskKnowledgeEntry.create!(:project_id => @project.id, :issue_id => 1,
                                            :problem => 'Drucker druckt nicht',
                                            :solution => 'Treiber neu installiert',
                                            :status => 'approved', :point_id => 'p1')
    @skipped = HelpdeskKnowledgeEntry.create!(:project_id => @project.id, :issue_id => 2,
                                              :status => 'skipped')
    RedmineExpertHelpdesk::AiFeatures.stubs(:kb_ready?).returns(true)
    @key = User.find(2).api_key # jsmith, Manager in project 1
  end

  def teardown
    Setting.rest_api_enabled = '0'
  end

  def auth
    { 'X-Redmine-API-Key' => @key }
  end

  def base
    "/projects/#{@project.id}/helpdesk/kb_entries"
  end

  def json
    ActiveSupport::JSON.decode(@response.body)
  end

  def grant!(*perms)
    Role.find(1).add_permission!(*perms)
  end

  def test_index_requires_authentication
    get "#{base}.json"
    assert_response :unauthorized
  end

  def test_index_forbidden_without_permission
    get "#{base}.json", :headers => auth
    assert_response :forbidden
  end

  def test_index_forbidden_without_module
    grant!(:view_helpdesk_kb)
    @project.disable_module!(:helpdesk)
    get "#{base}.json", :headers => auth
    assert_response :forbidden
  end

  def test_index_hides_skipped_by_default_and_filters
    grant!(:view_helpdesk_kb)
    get "#{base}.json", :headers => auth
    assert_response :success
    assert_equal [@entry.id], json['helpdesk_kb_entries'].map { |e| e['id'] }
    assert_equal 1, json['total_count']
    row = json['helpdesk_kb_entries'].first
    assert_equal 'approved', row['status']
    assert_equal true, row['indexed']
    assert_equal 1, row['issue']['id']
    assert_not row.key?('vector_sync')

    get "#{base}.json?status=all", :headers => auth
    assert_equal 2, json['total_count']

    get "#{base}.json?status=skipped", :headers => auth
    assert_equal [@skipped.id], json['helpdesk_kb_entries'].map { |e| e['id'] }

    get "#{base}.json?q=drucker", :headers => auth
    assert_equal 1, json['total_count']

    get "#{base}.json?issue_id=2&status=all", :headers => auth
    assert_equal [@skipped.id], json['helpdesk_kb_entries'].map { |e| e['id'] }
  end

  def test_show_and_xml
    grant!(:view_helpdesk_kb)
    get "/helpdesk/kb_entries/#{@entry.id}.json", :headers => auth
    assert_response :success
    assert_equal 'Treiber neu installiert', json['helpdesk_kb_entry']['solution']

    get "/helpdesk/kb_entries/#{@entry.id}.xml", :headers => auth
    assert_response :success
    assert_select 'helpdesk_kb_entry > problem', :text => 'Drucker druckt nicht'
  end

  def test_show_unknown_entry_is_not_found
    grant!(:view_helpdesk_kb)
    get '/helpdesk/kb_entries/999999.json', :headers => auth
    assert_response :not_found
  end

  def test_viewer_cannot_write
    grant!(:view_helpdesk_kb)
    put "/helpdesk/kb_entries/#{@entry.id}.json",
        :params => { :helpdesk_kb_entry => { :problem => 'x' } }, :headers => auth
    assert_response :forbidden
    post "/helpdesk/kb_entries/#{@entry.id}/reject.json", :headers => auth
    assert_response :forbidden
    assert_equal 'Drucker druckt nicht', @entry.reload.problem
  end

  def test_update_reembeds_and_reports_vector_sync
    grant!(:view_helpdesk_kb, :edit_helpdesk_kb)
    HelpdeskKnowledgeIngestJob.expects(:index_entry)
                              .with { |e| e.id == @entry.id && e.problem == 'Drucker offline' }.returns(true)
    put "/helpdesk/kb_entries/#{@entry.id}.json",
        :params => { :helpdesk_kb_entry => { :problem => 'Drucker offline' } }, :headers => auth
    assert_response :success
    assert_equal 'indexed', json['helpdesk_kb_entry']['vector_sync']
    assert_equal true, json['helpdesk_kb_entry']['curated']
    @entry.reload
    assert_equal 'Drucker offline', @entry.problem
    assert_equal 'Treiber neu installiert', @entry.solution, 'partial update keeps the solution'
    assert_equal 2, @entry.updated_by_id
  end

  def test_update_reports_failed_index
    grant!(:view_helpdesk_kb, :edit_helpdesk_kb)
    HelpdeskKnowledgeIngestJob.stubs(:index_entry).returns(false)
    put "/helpdesk/kb_entries/#{@entry.id}.json",
        :params => { :helpdesk_kb_entry => { :solution => 'Neu' } }, :headers => auth
    assert_response :success
    assert_equal 'index_failed', json['helpdesk_kb_entry']['vector_sync']
  end

  def test_update_rejects_unknown_status
    grant!(:view_helpdesk_kb, :edit_helpdesk_kb)
    put "/helpdesk/kb_entries/#{@entry.id}.json",
        :params => { :helpdesk_kb_entry => { :status => 'skipped' } }, :headers => auth
    assert_response :unprocessable_entity
    assert_equal 'approved', @entry.reload.status
  end

  # The stored status is not judged, only a sent one: correcting the text of a
  # rejected entry must not fail because "rejected" cannot be set directly.
  def test_text_update_of_rejected_entry
    grant!(:view_helpdesk_kb, :edit_helpdesk_kb)
    @entry.update_columns(:status => 'rejected', :point_id => nil)
    put "/helpdesk/kb_entries/#{@entry.id}.json",
        :params => { :helpdesk_kb_entry => { :problem => 'Korrigiert' } }, :headers => auth
    assert_response :success
    assert_equal 'removed', json['helpdesk_kb_entry']['vector_sync']
    assert_equal 'rejected', @entry.reload.status
  end

  def test_reject_unindexes_and_approve_reembeds
    grant!(:view_helpdesk_kb, :edit_helpdesk_kb)
    HelpdeskKnowledgeEntry.expects(:unindex).with { |e| e.id == @entry.id }.returns(true)
    post "/helpdesk/kb_entries/#{@entry.id}/reject.json", :headers => auth
    assert_response :success
    assert_equal 'rejected', json['helpdesk_kb_entry']['status']
    assert_equal 'removed', json['helpdesk_kb_entry']['vector_sync']

    HelpdeskKnowledgeIngestJob.expects(:index_entry).returns(true)
    post "/helpdesk/kb_entries/#{@entry.id}/approve.json", :headers => auth
    assert_response :success
    assert_equal 'approved', @entry.reload.status
    assert_equal 'indexed', json['helpdesk_kb_entry']['vector_sync']
  end

  def test_create_then_destroy
    grant!(:view_helpdesk_kb, :edit_helpdesk_kb, :manage_helpdesk_kb)
    HelpdeskKnowledgeIngestJob.expects(:index_entry).never
    assert_difference 'HelpdeskKnowledgeEntry.count', 1 do
      post "#{base}.json", :params => { :helpdesk_kb_entry => {
        :issue_id => '#3', :problem => 'VPN trennt', :solution => 'MTU gesenkt'
      } }, :headers => auth
    end
    assert_response :created
    body = json['helpdesk_kb_entry']
    assert_equal 3, body['issue']['id']
    assert_equal 'pending', body['status'], 'status defaults to pending'
    assert_equal 'removed', body['vector_sync']

    assert_difference 'HelpdeskKnowledgeEntry.count', -1 do
      delete "/helpdesk/kb_entries/#{body['id']}.json", :headers => auth
    end
    assert_response :no_content
  end

  def test_create_validation_errors
    grant!(:view_helpdesk_kb, :edit_helpdesk_kb)
    # Issue 4 belongs to project 2.
    post "#{base}.json", :params => { :helpdesk_kb_entry => { :issue_id => 4, :problem => 'x' } },
                         :headers => auth
    assert_response :unprocessable_entity
    post "#{base}.json", :params => { :helpdesk_kb_entry => { :issue_id => 1, :problem => 'x' } },
                         :headers => auth
    assert_response :unprocessable_entity, 'one entry per issue'
  end

  def test_destroy_keeps_row_when_unindex_fails
    grant!(:view_helpdesk_kb, :edit_helpdesk_kb, :manage_helpdesk_kb)
    HelpdeskKnowledgeEntry.stubs(:unindex).returns(false)
    assert_no_difference 'HelpdeskKnowledgeEntry.count' do
      delete "/helpdesk/kb_entries/#{@entry.id}.json", :headers => auth
    end
    assert_response :unprocessable_entity
  end

  def test_editor_cannot_destroy_or_reindex
    grant!(:view_helpdesk_kb, :edit_helpdesk_kb)
    delete "/helpdesk/kb_entries/#{@entry.id}.json", :headers => auth
    assert_response :forbidden
    post "#{base}/reindex.json", :headers => auth
    assert_response :forbidden
    post "#{base}/reextract.json", :headers => auth
    assert_response :forbidden
  end

  def test_reindex_queues_job
    grant!(:manage_helpdesk_kb)
    HelpdeskKnowledgeReindexJob.expects(:perform_later).with(@project.id)
    post "#{base}/reindex.json", :headers => auth
    assert_response :success
    assert_equal({ 'action' => 'reindex', 'queued' => true, 'count' => 1 }, json['kb_job'])
  end

  def test_reindex_refused_when_kb_not_ready
    grant!(:manage_helpdesk_kb)
    RedmineExpertHelpdesk::AiFeatures.stubs(:kb_ready?).returns(false)
    HelpdeskKnowledgeReindexJob.expects(:perform_later).never
    post "#{base}/reindex.json", :headers => auth
    assert_response :unprocessable_entity
    assert json['errors'].present?
  end

  def test_reextract_queues_job_or_reports_nothing_to_do
    grant!(:manage_helpdesk_kb)
    scope = mock('scope')
    scope.stubs(:count).returns(4)
    HelpdeskKnowledgeReextractJob.stubs(:scope_for).with(@project.id, :all => true).returns(scope)
    HelpdeskKnowledgeReextractJob.expects(:perform_later)
                                 .with { |pid, opts| pid == @project.id && opts[:all] == true && opts[:requested_at] }
    post "#{base}/reextract.json", :params => { :all => '1' }, :headers => auth
    assert_response :success
    assert_equal({ 'action' => 'reextract', 'queued' => true, 'count' => 4 }, json['kb_job'])

    empty = mock('empty')
    empty.stubs(:count).returns(0)
    HelpdeskKnowledgeReextractJob.stubs(:scope_for).with(@project.id, :all => false).returns(empty)
    post "#{base}/reextract.json", :headers => auth
    assert_response :success
    assert_equal false, json['kb_job']['queued']
  end
end
