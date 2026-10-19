# Manuelle Kuratierung der Wissensbasis aus der Ticket-Seitenleiste:
#  - ingest:  geschlossenes Ticket manuell aufnehmen (force -> sofort approved)
#  - approve: einen im manual-Modus erzeugten pending-Eintrag freigeben
# Permission: send_helpdesk_reply (as before) or edit_helpdesk_kb (KB editor role).
# The full list/edit UI lives in HelpdeskKbEntriesController ("Knowledge base" tab).
class HelpdeskKnowledgeController < ApplicationController
  before_action :find_issue_and_project
  before_action :authorize_manage

  def ingest
    unless RedmineExpertHelpdesk::AiFeatures.kb_ready?
      flash[:warning] = l(:text_helpdesk_kb_not_configured)
      return redirect_to issue_path(@issue)
    end

    HelpdeskKnowledgeIngestJob.perform_later(@issue.id, :force => true)
    flash[:notice] = l(:notice_helpdesk_kb_ingest_queued)
    redirect_to issue_path(@issue)
  end

  def approve
    entry = HelpdeskKnowledgeEntry.find_by(:issue_id => @issue.id)
    if entry&.pending?
      entry.curate!(User.current, :status => 'approved')
      # Row-locked like the tab, so an overlapping delete or reject cannot be
      # undone by this embedding (HelpdeskKnowledgeEntry#sync_vector!).
      case entry.sync_vector!
      when :indexed       then flash[:notice]  = l(:notice_helpdesk_kb_approved)
      when :problem_blank then flash[:warning] = l(:text_helpdesk_kb_problem_blank)
      when :removed       then flash[:warning] = l(:text_helpdesk_kb_nothing_to_approve)
      else                     flash[:warning] = l(:text_helpdesk_kb_saved_not_indexed)
      end
    else
      flash[:warning] = l(:text_helpdesk_kb_nothing_to_approve)
    end
    redirect_to issue_path(@issue)
  end

  private

  def find_issue_and_project
    @issue   = Issue.find(params[:issue_id])
    @project = @issue.project
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  def authorize_manage
    allowed = User.current.allowed_to?(:send_helpdesk_reply, @project) ||
              User.current.allowed_to?(:edit_helpdesk_kb, @project)
    deny_access unless allowed
  end
end
