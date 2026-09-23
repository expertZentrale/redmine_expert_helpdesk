# Blacklisting an attachment's content, from the ticket page and back again from
# the project settings.
#
# +create+ and +preview+ are reached with an attachment id and derive the project
# from the ticket that attachment hangs on; +destroy+ is the project settings list
# and is reached with a project id. All three need :manage_helpdesk, mapped in
# init.rb, so Redmine's own authorize covers them once @project is set.
class HelpdeskAttachmentBlacklistsController < ApplicationController
  before_action :find_attachment, :only => [:preview, :create]
  before_action :find_entry, :only => [:destroy]
  before_action :authorize
  before_action :require_eligible_attachment, :only => [:preview, :create]

  # How many copies create would delete, so the agent confirms against a real
  # number instead of a warning in the abstract.
  def preview
    digest = HelpdeskAttachmentBlacklist.digest_for(@attachment)
    if digest.blank?
      return render :json => { :error => l(:error_helpdesk_attachment_unreadable) }, :status => :unprocessable_entity
    end

    entry = HelpdeskAttachmentBlacklist.new(:project_id => @project.id,
                                            :digest => digest,
                                            :filesize => @attachment.filesize)
    render :json => {
      :filename => @attachment.filename,
      :copies   => RedmineExpertHelpdesk::AttachmentBlacklist.count_copies(@project, entry)
    }
  end

  def create
    digest = HelpdeskAttachmentBlacklist.digest_for(@attachment)
    if digest.blank?
      flash[:error] = l(:error_helpdesk_attachment_unreadable)
      return redirect_to issue_path(@issue)
    end

    entry = blacklist_entry(digest)
    unless entry.save
      flash[:error] = entry.errors.full_messages.join(', ')
      return redirect_to issue_path(@issue)
    end

    removed = RedmineExpertHelpdesk::AttachmentBlacklist.purge!(@project, entry)
    flash[:notice] = l(:notice_helpdesk_attachment_blacklisted,
                       :file => entry.label, :count => removed)
    redirect_to issue_path(@issue)
  end

  def destroy
    @entry.destroy
    flash[:notice] = l(:notice_successful_delete)
    redirect_to settings_project_path(@project, :tab => 'expert_helpdesk')
  end

  private

  # The type and size guards from the settings, checked again here. The button is
  # only drawn for eligible files, but a page open since the settings changed still
  # offers it, and nothing stops a request arriving without the page at all.
  def require_eligible_attachment
    return if RedmineExpertHelpdesk::AttachmentBlacklist.eligible?(@attachment, @project)

    message = l(:error_helpdesk_attachment_not_blacklistable, :file => @attachment.filename)
    if request.get?
      render :json => { :error => message }, :status => :unprocessable_entity
    else
      flash[:error] = message
      redirect_to issue_path(@issue)
    end
  end

  # An existing entry is reused rather than rejected as a duplicate: two agents
  # hitting the same signature logo on two tickets is the normal case, and the
  # second one still expects their ticket to be cleaned up.
  def blacklist_entry(digest)
    entry = HelpdeskAttachmentBlacklist.find_or_initialize_by(:project_id => @project.id,
                                                              :digest => digest)
    entry.filename ||= @attachment.filename
    entry.content_type ||= @attachment.content_type
    entry.filesize = @attachment.filesize
    entry.user_id ||= User.current.id
    entry.created_on ||= Time.current
    entry
  end

  # The project is the ticket's, never a parameter - otherwise an agent could
  # blacklist a file they may see into a project they may not manage.
  def find_attachment
    @attachment = Attachment.find(params[:attachment_id])
    @issue = issue_of(@attachment)
    raise ActiveRecord::RecordNotFound if @issue.nil?
    return render_403 unless @attachment.visible?(User.current)

    @project = @issue.project
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  # Only ticket attachments can be blacklisted: the feature exists for incoming
  # mail, and a wiki page or document has no helpdesk project to scope the entry to.
  def issue_of(attachment)
    case attachment.container
    when Issue
      attachment.container
    when Journal
      journalized = attachment.container.journalized
      journalized if journalized.is_a?(Issue)
    end
  end

  def find_entry
    @project = Project.find(params[:project_id])
    @entry = HelpdeskAttachmentBlacklist.where(:project_id => @project.id).find(params[:id])
  rescue ActiveRecord::RecordNotFound
    render_404
  end
end
