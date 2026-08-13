# Liefert Text fuer das Notizfeld des Tickets: Zitate (Originalmail, kompletter
# Verlauf, Mail-Verlauf) und ausgewertete Antwortvorlagen.
#
# Antwortet immer mit JSON; das Einfuegen uebernimmt die Werkzeugleiste im
# Bearbeitungsformular (helpdesk/_note_toolbar). JSON statt einer .js.erb, weil
# Redmine 7 Skript-Antworten ueber @rails/request.js einbindet und Redmine 5.1
# ueber jQuery-UJS — ein fetch() mit JSON verhaelt sich auf beiden gleich.
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

  # Fehler werden bewusst selbst gerendert statt ueber render_404/deny_access:
  # deren Huelle unterscheidet sich zwischen den unterstuetzten Redmine-Versionen
  # (Redmine 7 verpackt sie fuer JSON in eine 422-Antwort). Die Werkzeugleiste
  # braucht hier verlaessliche Statuscodes und ein flaches { "error": "..." }.
  def render_error(message, status = :unprocessable_entity)
    render :json => { :error => message }, :status => status
  end

  # Issue.visible statt Issue.find: dieser Endpunkt gibt Journaltext heraus,
  # die Sichtbarkeit muss also schon beim Laden greifen, nicht erst ueber die
  # Berechtigung.
  def find_issue
    @issue = Issue.visible.find(params[:issue_id])
    @project = @issue.project
  rescue ActiveRecord::RecordNotFound
    render_error(l(:notice_file_not_found), :not_found)
  end

  # send_helpdesk_reply wie beim Antwortformular: der Text entsteht, um eine
  # Kundenantwort zu verfassen. view_helpdesk_info waere eine :read-Berechtigung,
  # die in oeffentlichen Projekten auch Nichtmitglieder haben.
  def authorize_note_content
    return render_error(l(:notice_file_not_found), :not_found) unless @project.module_enabled?(:helpdesk)
    return if User.current.allowed_to?(:send_helpdesk_reply, @project)

    render_error(l(:notice_not_authorized), :forbidden)
  end
end
