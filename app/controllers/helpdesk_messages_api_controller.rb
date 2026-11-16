# REST API lookup of the mail log by Message-ID: which ticket a mail went into,
# or which reply we sent with that ID. JSON/XML via .api.rsb.
#
# Global on purpose: a caller holding a Message-ID (from a mail client or a
# message trace) does not know the project. project_id narrows it to one.
# Visibility is the ticket API's: a message is listed when its issue is visible
# (view_issues) and its project has the helpdesk module enabled - the same rule
# that already shows a ticket's messages under ?include=messages.
#
# message_id is required. There is no listing of the whole mail log here; that
# is what the ticket endpoint is for.
class HelpdeskMessagesApiController < ApplicationController
  # Several IDs travel in one query string; a few dozen keep the URL well under
  # the usual 8 KB proxy limit even for long Exchange IDs.
  MAX_IDS = 50

  before_action :require_login
  before_action :find_optional_api_project
  accept_api_auth :index

  def index
    ids = requested_ids
    return render_api_errors(l(:text_helpdesk_message_id_required)) if ids.empty?
    return render_api_errors(l(:text_helpdesk_message_id_too_many, :count => MAX_IDS)) if ids.size > MAX_IDS

    scope = HelpdeskMessage.visible(User.current)
                           .where(:message_id => ids.flat_map { |id| HelpdeskMessage.message_id_variants(id) })
                           .where(Project.table_name => { :id => helpdesk_project_ids })
    scope = scope.where(Issue.table_name => { :project_id => @project.id }) if @project

    @offset, @limit = api_offset_and_limit
    @message_count = scope.count
    @messages = scope.preload(:issue => :project).order(:id => :asc).limit(@limit).offset(@offset).to_a
    respond_to { |format| format.api }
  end

  private

  # message_id=a,b or message_id[]=a&message_id[]=b, either spelling of each ID.
  # A comma cannot occur in a Message-ID outside a domain literal, which mail
  # software does not generate.
  def requested_ids
    raw = params[:message_id]
    list = raw.is_a?(Array) ? raw : raw.to_s.split(',')
    list.map { |id| HelpdeskMessage.bare_message_id(id) }.compact.uniq
  end

  def helpdesk_project_ids
    EnabledModule.where(:name => 'helpdesk').select(:project_id)
  end

  def find_optional_api_project
    return if params[:project_id].blank?

    @project = Project.find(params[:project_id])
    render_404 unless @project.visible?
  rescue ActiveRecord::RecordNotFound
    render_404
  end
end
