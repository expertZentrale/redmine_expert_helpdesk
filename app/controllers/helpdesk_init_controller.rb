# Verknuepft einen Kundenkontakt manuell mit einem bestehenden Ticket
# und sendet optional eine initiale Helpdesk-Mail.
class HelpdeskInitController < ApplicationController
  before_action :find_project_by_project_id
  before_action :authorize
  before_action :find_issue

  def create
    hd        = params[:helpdesk_init] || {}
    send_mail = hd[:send_mail] == '1'

    result = RedmineExpertHelpdesk::InitMailer.call(
      :issue         => @issue,
      :contact_email => hd[:contact_email].to_s,
      :contact_name  => hd[:contact_name].to_s.strip.presence,
      :cc            => hd[:cc].to_s,
      :bcc           => hd[:bcc].to_s,
      :mailbox       => resolve_mailbox(hd[:mailbox_id]),
      :user          => User.current,
      :send_mail     => send_mail,
      :mail_body     => hd[:mail_body].to_s.strip.presence,
      :move_cc       => hd[:move_cc] == '1'
    )

    flash[:notice] = ERB::Util.h(init_notice(result))
    redirect_to issue_path(@issue)
  rescue StandardError => e
    # Redmine renders flash messages as HTML; the message may carry a project
    # name or a mail server's answer.
    flash[:error] = ERB::Util.h(e.message)
    redirect_to issue_path(@issue)
  end

  private

  def init_notice(result)
    parts = []
    parts << l(result.mailed ? :notice_helpdesk_init_mail_sent : :notice_helpdesk_contact_assigned) if result.contact
    if result.handovers.any?
      targets = RedmineExpertHelpdesk::InitMailer.handover_list(result.handovers)
      parts << l(result.contact ? :notice_helpdesk_init_handed_over : :notice_helpdesk_init_handover_only,
                 :targets => targets)
    end
    parts.join(' ')
  end

  def resolve_mailbox(mailbox_id)
    @project.helpdesk_mailboxes.enabled.find_by(:id => mailbox_id.to_i) ||
      @project.helpdesk_mailboxes.enabled.first
  end

  # The project permission alone is not enough: the initial mail sends the
  # ticket's description and attachments out, and a hand-over copies them into
  # another project - neither may start from a ticket the agent cannot see.
  def find_issue
    @issue = Issue.find(params[:issue_id])
    return render_404 unless @issue.project == @project

    render_403 unless @issue.visible?
  rescue ActiveRecord::RecordNotFound
    render_404
  end
end
