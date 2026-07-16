# Verknuepft einen Kundenkontakt manuell mit einem bestehenden Ticket
# und sendet optional eine initiale Helpdesk-Mail.
class HelpdeskInitController < ApplicationController
  before_action :find_project_by_project_id
  before_action :authorize
  before_action :find_issue

  def create
    hd        = params[:helpdesk_init] || {}
    to_list   = hd[:contact_email].to_s.split(/[,;]/).map { |a| a.strip.downcase }.reject(&:blank?)
    name      = hd[:contact_name].to_s.strip
    send_mail = hd[:send_mail] == '1'
    mail_body = hd[:mail_body].to_s.strip
    mailbox   = resolve_mailbox(hd[:mailbox_id])

    unless to_list.first.to_s.match?(/\A[^@\s]+@[^@\s]+\z/)
      flash[:error] = l(:error_helpdesk_invalid_email)
      return redirect_to issue_path(@issue)
    end

    RedmineExpertHelpdesk::InitMailer.call(
      :issue         => @issue,
      :contact_email => to_list.join(', '),
      :contact_name  => name.presence,
      :cc            => hd[:cc].to_s,
      :bcc           => hd[:bcc].to_s,
      :mailbox       => mailbox,
      :user          => User.current,
      :send_mail     => send_mail,
      :mail_body     => mail_body.presence
    )

    flash[:notice] = send_mail ? l(:notice_helpdesk_init_mail_sent) : l(:notice_helpdesk_contact_assigned)
    redirect_to issue_path(@issue)
  rescue StandardError => e
    flash[:error] = e.message
    redirect_to issue_path(@issue)
  end

  private

  def resolve_mailbox(mailbox_id)
    @project.helpdesk_mailboxes.enabled.find_by(:id => mailbox_id.to_i) ||
      @project.helpdesk_mailboxes.enabled.first
  end

  def find_issue
    @issue = Issue.find(params[:issue_id])
    render_404 unless @issue.project == @project
  rescue ActiveRecord::RecordNotFound
    render_404
  end
end
