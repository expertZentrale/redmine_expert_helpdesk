# REST API for the knowledge base (HelpdeskKnowledgeEntry), the counterpart of the
# "Knowledge base" project tab. JSON/XML via .api.rsb.
#
# Same three permission tiers as the tab (init.rb): view_helpdesk_kb -> index/show,
# edit_helpdesk_kb -> create/update/approve/reject, manage_helpdesk_kb -> destroy and
# the per-project reindex/reextract jobs. Every write goes through the SQL row and
# then HelpdeskKnowledgeEntry#sync_vector!; its result is returned as `vector_sync`,
# because the UI reports it as a flash message and an API caller has no other way
# to learn that an approved entry did not make it into the vector store.
class HelpdeskKbEntriesApiController < ApplicationController
  before_action :find_project_by_project_id, :only => [:index, :create, :reindex, :reextract]
  before_action :find_entry, :only => [:show, :update, :destroy, :approve, :reject]
  before_action :authorize
  accept_api_auth :index, :show, :create, :update, :destroy, :approve, :reject, :reindex, :reextract

  # Statuses an API caller can set directly; rejected has its own endpoint and
  # skipped is the model's own verdict.
  WRITABLE_STATUSES = %w[approved pending].freeze

  def index
    scope = HelpdeskKnowledgeEntry.where(:project_id => @project.id)
    # Same default as the tab: "skipped" (no solution found) is hidden unless asked for.
    status = params[:status].to_s
    scope = case status
            when '' then scope.where.not(:status => 'skipped')
            when 'all' then scope
            else scope.where(:status => status.split(','))
            end
    scope = scope.where(:issue_id => params[:issue_id].to_s.split(',').map(&:to_i)) if params[:issue_id].present?
    scope = scope.search(params[:q]) if params[:q].present?

    @offset, @limit = api_offset_and_limit
    @entry_count = scope.count
    @entries = scope.includes(:issue, :project, :updated_by)
                    .order(:updated_at => :desc, :id => :desc)
                    .limit(@limit).offset(@offset)
    respond_to { |format| format.api }
  end

  def show
    respond_to { |format| format.api }
  end

  def create
    attrs = entry_params
    @entry = HelpdeskKnowledgeEntry.new(:project_id => @project.id)
    @entry.issue_id = attrs[:issue_id].to_s.delete('#').strip.presence
    assign_texts(@entry, attrs)
    return unless writable_status?(@entry, attrs)

    @entry.status = attrs[:status].presence || 'pending'

    @entry.updated_by_id = User.current.id
    @entry.curated_at    = Time.current
    if @entry.save
      @vector_sync = @entry.sync_vector!
      respond_to { |format| format.api { render :action => 'show', :status => :created } }
    else
      render_validation_errors(@entry)
    end
  end

  # Partial: only the keys that were sent change anything. 200 with the entry
  # rather than Redmine's usual 204, so the caller sees vector_sync.
  def update
    attrs = entry_params
    assign_texts(@entry, attrs)
    return unless writable_status?(@entry, attrs)

    @entry.status = attrs[:status].to_s if attrs[:status].present?

    @entry.updated_by_id = User.current.id
    @entry.curated_at    = Time.current
    if @entry.save
      @vector_sync = @entry.sync_vector!
      respond_to { |format| format.api { render :action => 'show' } }
    else
      render_validation_errors(@entry)
    end
  end

  def approve
    curate('approved')
  end

  def reject
    curate('rejected')
  end

  def destroy
    # Point first, under the row lock (see HelpdeskKnowledgeEntry#destroy_with_vector!).
    return render_api_errors(l(:text_helpdesk_kb_unindex_failed)) unless @entry.destroy_with_vector!

    render_api_ok
  end

  # Rebuilds the project's vector namespace in the background (no LLM call).
  # 200, not 202: Redmine itself never answers 202, and clients built on its
  # conventions (python-redmine among them) treat it as an unknown error.
  def reindex
    return render_api_errors(l(:text_helpdesk_kb_not_configured)) unless RedmineExpertHelpdesk::AiFeatures.kb_ready?

    HelpdeskKnowledgeReindexJob.perform_later(@project.id)
    @job = { :action => 'reindex', :queued => true,
             :count => HelpdeskKnowledgeEntry.approved.where(:project_id => @project.id).count }
    respond_to { |format| format.api { render :action => 'kb_job' } }
  end

  # Re-extracts entries at the project's current detail level; all=1 re-extracts
  # every eligible entry. Each entry costs one AI call.
  def reextract
    return render_api_errors(l(:text_helpdesk_kb_not_configured)) unless RedmineExpertHelpdesk::AiFeatures.kb_ready?

    all   = ActiveModel::Type::Boolean.new.cast(params[:all]) ? true : false
    count = HelpdeskKnowledgeReextractJob.scope_for(@project.id, :all => all).count
    if count.positive?
      HelpdeskKnowledgeReextractJob.perform_later(@project.id, :all => all, :requested_at => Time.current)
    end
    @job = { :action => 'reextract', :queued => count.positive?, :count => count }
    respond_to { |format| format.api { render :action => 'kb_job' } }
  end

  private

  # Entries are addressed globally by id; the project comes from the record.
  def find_entry
    @entry = HelpdeskKnowledgeEntry.find(params[:id])
    @project = @entry.project
    render_404 unless @project
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  def entry_params
    params[:helpdesk_kb_entry] || {}
  end

  def assign_texts(entry, attrs)
    entry.problem  = attrs[:problem].to_s.strip  if attrs.key?(:problem)
    entry.solution = attrs[:solution].to_s.strip if attrs.key?(:solution)
  end

  # The tab coerces an unknown status to pending; an API caller needs to hear about
  # it. Only a sent status is checked, so a text-only update of a rejected entry works.
  def writable_status?(entry, attrs)
    return true if attrs[:status].blank? || WRITABLE_STATUSES.include?(attrs[:status].to_s)

    entry.errors.add(:status, :inclusion)
    render_validation_errors(entry)
    false
  end

  def curate(status)
    @entry.curate!(User.current, :status => status)
    @vector_sync = @entry.sync_vector!
    respond_to { |format| format.api { render :action => 'show' } }
  end
end
