# Verwaltung der Automatisierungsregeln eines Postfachs
class HelpdeskRulesController < ApplicationController
  before_action :find_mailbox
  before_action :authorize

  def create
    @rule = @mailbox.helpdesk_rules.build
    @rule.safe_attributes = params[:helpdesk_rule]
    unless @rule.save
      flash[:error] = @rule.errors.full_messages.join(', ')
    end
    redirect_to edit_helpdesk_mailbox_path(@mailbox, :project_id => @project)
  end

  def destroy
    @mailbox.helpdesk_rules.find(params[:id]).destroy
    redirect_to edit_helpdesk_mailbox_path(@mailbox, :project_id => @project)
  end

  private

  def find_mailbox
    @mailbox = HelpdeskMailbox.find(params[:helpdesk_mailbox_id])
    @project = @mailbox.project
  rescue ActiveRecord::RecordNotFound
    render_404
  end
end
