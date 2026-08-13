# Delivers text for the ticket's note field: quotes (original mail, complete
# conversation, mail conversation) and expanded answer templates.
#
# Always answers with JSON; the insertion is done by the toolbar of the edit
# form (helpdesk/_note_toolbar). JSON rather than a .js.erb, because Redmine 7
# runs script responses through @rails/request.js and Redmine 5.1 through
# jQuery UJS — a fetch() returning JSON behaves identically on both.
class HelpdeskNoteContentController < ApplicationController
  before_action :find_issue
  before_action :authorize_note_content

  SOURCES = %w[description conversation mail_conversation template].freeze

  def create
    source = params[:source].to_s
    unless SOURCES.include?(source)
      return render_error(l(:error_helpdesk_note_content_unknown_source))
    end

    result =
      case source
      when 'description'       then RedmineExpertHelpdesk::NoteQuoter.description(@issue)
      when 'conversation'      then RedmineExpertHelpdesk::NoteQuoter.conversation(@issue)
      when 'mail_conversation' then RedmineExpertHelpdesk::NoteQuoter.conversation(@issue, :mail_only => true)
      else                          template_result
      end
    return if performed?

    if result.content.blank?
      return render_error(l(:error_helpdesk_note_content_empty))
    end

    render :json => { :content   => result.content,
                      :truncated => result.truncated?,
                      :omitted   => result.omitted.to_i }
  end

  private

  def template_result
    template = HelpdeskReplyTemplate.active.available_for(@project).find_by(:id => params[:template_id])
    if template.nil?
      render_error(l(:error_helpdesk_reply_template_not_found), :not_found)
      return nil
    end

    contact = HelpdeskTicketInfo.for_issue(@issue)&.helpdesk_contact
    RedmineExpertHelpdesk::NoteQuoter::Result.new(
      template.render_for(@issue, contact, User.current), 0
    )
  end

  # Errors are rendered here rather than via render_404/deny_access on purpose:
  # their envelope differs between the supported Redmine versions (Redmine 7
  # wraps them into a 422 response for JSON). The toolbar needs dependable
  # status codes and a flat { "error": "..." }.
  def render_error(message, status = :unprocessable_entity)
    render :json => { :error => message }, :status => status
  end

  # Issue.visible rather than Issue.find: this endpoint hands out journal text,
  # so visibility has to apply at load time, not only through the permission.
  def find_issue
    @issue = Issue.visible.find(params[:issue_id])
    @project = @issue.project
  rescue ActiveRecord::RecordNotFound
    render_error(l(:notice_file_not_found), :not_found)
  end

  # send_helpdesk_reply as for the reply form: the text exists to compose a
  # customer reply. view_helpdesk_info would be a :read permission that
  # non-members hold in public projects too.
  def authorize_note_content
    return render_error(l(:notice_file_not_found), :not_found) unless @project.module_enabled?(:helpdesk)
    return if User.current.allowed_to?(:send_helpdesk_reply, @project)

    render_error(l(:notice_not_authorized), :forbidden)
  end
end
