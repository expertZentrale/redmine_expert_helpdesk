# Manuelle Kuratierung der Wissensbasis aus der Ticket-Seitenleiste:
#  - ingest:  geschlossenes Ticket manuell aufnehmen (force -> sofort approved)
#  - approve: einen im manual-Modus erzeugten pending-Eintrag freigeben
# Berechtigung wie beim Antworten: send_helpdesk_reply.
class HelpdeskKnowledgeController < ApplicationController
  before_action :find_issue_and_project
  before_action :authorize_manage

  def ingest
    unless kb_ready?
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
      entry.update(:status => 'approved')
      HelpdeskKnowledgeIngestJob.index_entry(entry)
      flash[:notice] = l(:notice_helpdesk_kb_approved)
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
    deny_access unless User.current.allowed_to?(:send_helpdesk_reply, @project)
  end

  def kb_ready?
    settings = Setting.plugin_redmine_expert_helpdesk
    RedmineExpertHelpdesk::AiFeatures.kb_enabled? &&
      RedmineExpertHelpdesk::KnowledgeStore.for(settings).configured? &&
      RedmineExpertHelpdesk::AiClient.new(settings).embed_configured?
  end
end
