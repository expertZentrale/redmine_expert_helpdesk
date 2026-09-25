# "Knowledge base" project tab: lets people verify and correct what the RAG extraction
# stored. The SQL row (HelpdeskKnowledgeEntry) is the system of record; every write
# here re-embeds the entry (approved) or removes its point (anything else), so the
# vector store never keeps a vector computed from outdated text.
#
# Permissions (init.rb): view_helpdesk_kb -> index/show, edit_helpdesk_kb -> write
# entries, manage_helpdesk_kb -> destroy and project reindex.
class HelpdeskKbEntriesController < ApplicationController
  before_action :find_project_by_project_id
  before_action :authorize
  before_action :find_entry, :only => [:show, :edit, :update, :destroy, :approve, :reject]

  helper :sort
  include SortHelper

  PER_PAGE = 25
  # Statuses a person can set from the form (skipped is the model's own verdict).
  FORM_STATUSES = %w[approved pending].freeze
  SORT_COLUMNS = {
    'issue'   => 'helpdesk_knowledge_entries.issue_id',
    'status'  => 'helpdesk_knowledge_entries.status',
    'updated' => 'helpdesk_knowledge_entries.updated_at'
  }.freeze

  def index
    sort_init 'updated', 'desc'
    sort_update SORT_COLUMNS

    scope = HelpdeskKnowledgeEntry.where(:project_id => @project.id)
    @status = params[:status].to_s
    @status = '' unless @status.empty? || @status == 'all' || HelpdeskKnowledgeEntry::STATUSES.include?(@status)
    # Default hides "skipped" (no solution found): noise for the reviewer.
    scope = case @status
            when '' then scope.where.not(:status => 'skipped')
            when 'all' then scope
            else scope.where(:status => @status)
            end
    @q = params[:q].to_s.strip
    scope = scope.search(@q) if @q.present?

    @counts = HelpdeskKnowledgeEntry.where(:project_id => @project.id).group(:status).count
    @entry_count = scope.count
    @entry_pages = Redmine::Pagination::Paginator.new(@entry_count, PER_PAGE, params['page'])
    @entries = scope.includes(:issue, :updated_by)
                    .order(Arel.sql([sort_clause, 'helpdesk_knowledge_entries.id DESC'].compact.join(', ')))
                    .limit(@entry_pages.per_page)
                    .offset(@entry_pages.offset)
    @kb_ready = RedmineExpertHelpdesk::AiFeatures.kb_ready?
  end

  def show
    @kb_ready = RedmineExpertHelpdesk::AiFeatures.kb_ready?
  end

  def new
    @entry = HelpdeskKnowledgeEntry.new(:project_id => @project.id, :status => 'approved',
                                        :issue_id => params[:issue_id])
  end

  def create
    @entry = HelpdeskKnowledgeEntry.new(:project_id => @project.id)
    @entry.issue_id = params.dig(:helpdesk_knowledge_entry, :issue_id).to_s.delete('#').strip
    assign_texts(@entry)
    @entry.status = form_status
    @entry.updated_by_id = User.current.id
    @entry.curated_at    = Time.current
    if @entry.save
      sync_vector(@entry)
      redirect_to helpdesk_kb_entry_path(@entry, :project_id => @project)
    else
      render :action => 'new'
    end
  end

  def edit
  end

  def update
    assign_texts(@entry)
    @entry.status = form_status if params.dig(:helpdesk_knowledge_entry, :status).present?
    @entry.updated_by_id = User.current.id
    @entry.curated_at    = Time.current
    if @entry.save
      sync_vector(@entry)
      redirect_to helpdesk_kb_entry_path(@entry, :project_id => @project)
    else
      render :action => 'edit'
    end
  end

  def approve
    @entry.curate!(User.current, :status => 'approved')
    sync_vector(@entry)
    redirect_back_or_default helpdesk_kb_entries_path(:project_id => @project)
  end

  def reject
    @entry.curate!(User.current, :status => 'rejected')
    sync_vector(@entry)
    redirect_back_or_default helpdesk_kb_entries_path(:project_id => @project)
  end

  def destroy
    # Point first: once the row is gone, nothing records which point to remove, and a
    # point without a row would stay searchable. So a failed removal keeps the row.
    if @entry.point_id.present? && !HelpdeskKnowledgeEntry.unindex(@entry)
      flash[:error] = l(:text_helpdesk_kb_unindex_failed)
      return redirect_to helpdesk_kb_entry_path(@entry, :project_id => @project)
    end
    @entry.destroy
    flash[:notice] = l(:notice_successful_delete)
    redirect_to helpdesk_kb_entries_path(:project_id => @project)
  end

  def reindex
    unless RedmineExpertHelpdesk::AiFeatures.kb_ready?
      flash[:warning] = l(:text_helpdesk_kb_not_configured)
      return redirect_to helpdesk_kb_entries_path(:project_id => @project)
    end

    HelpdeskKnowledgeReindexJob.perform_later(@project.id)
    flash[:notice] = l(:notice_helpdesk_kb_reindex_queued)
    redirect_to helpdesk_kb_entries_path(:project_id => @project)
  end

  private

  def find_entry
    @entry = HelpdeskKnowledgeEntry.where(:project_id => @project.id).find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  def assign_texts(entry)
    attrs = params[:helpdesk_knowledge_entry] || {}
    entry.problem  = attrs[:problem].to_s.strip  if attrs.key?(:problem)
    entry.solution = attrs[:solution].to_s.strip if attrs.key?(:solution)
  end

  def form_status
    s = params.dig(:helpdesk_knowledge_entry, :status).to_s
    FORM_STATUSES.include?(s) ? s : 'pending'
  end

  # Approved -> (re-)embed; any other status -> must not be searchable. Synchronous,
  # so the person sees at once whether the vector store took the change.
  def sync_vector(entry)
    if entry.approved?
      if !RedmineExpertHelpdesk::AiFeatures.kb_ready?
        flash[:warning] = l(:text_helpdesk_kb_saved_not_indexed)
      elsif entry.problem.blank?
        flash[:warning] = l(:text_helpdesk_kb_problem_blank)
      elsif HelpdeskKnowledgeIngestJob.index_entry(entry)
        flash[:notice] = l(:notice_helpdesk_kb_saved_indexed)
      else
        flash[:warning] = l(:text_helpdesk_kb_saved_not_indexed)
      end
    elsif entry.point_id.present? && !HelpdeskKnowledgeEntry.unindex(entry)
      # point_id stays set, so the entry still shows as indexed and the next
      # "Rebuild index" removes the point.
      flash[:warning] = l(:text_helpdesk_kb_unindex_failed)
    else
      flash[:notice] = l(:notice_successful_update)
    end
  end
end
