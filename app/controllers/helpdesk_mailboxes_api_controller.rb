# REST API for helpdesk mailboxes (per-project mail backend configuration).
# JSON/XML via .api.rsb.
#
# Authorization is `manage_helpdesk` for reading as well as writing: a mailbox
# exposes hosts, usernames, OAuth client/tenant ids and the last connection error,
# which `view_helpdesk_info` (granted to anyone who may see customer data) has no
# business seeing.
#
# Secrets are write-only. `mail_password`, `oauth_client_secret` and `oauth_sa_key`
# can be set but never read back; responses carry `*_set` booleans instead. Their
# write semantics come from HelpdeskMailbox#assign_secret: omitting the key (or
# sending an empty string) keeps the stored value, sending "-"
# (HelpdeskMailbox::CLEAR_SECRET) clears it. `oauth_refresh_token` cannot be set at
# all — it only comes from the interactive consent flow in the UI.
class HelpdeskMailboxesApiController < ApplicationController
  before_action :find_project_by_project_id, :only => [:index, :create]
  before_action :find_mailbox, :only => [:show, :update, :destroy, :test_connection]
  before_action :require_helpdesk_module
  before_action :authorize_manage
  accept_api_auth :index, :show, :create, :update, :destroy, :test_connection

  def index
    scope = HelpdeskMailbox.where(:project_id => @project.id)
    if params.key?(:enabled)
      scope = scope.where(:enabled => ActiveModel::Type::Boolean.new.cast(params[:enabled]))
    end
    scope = scope.where(:provider => params[:provider].to_s) if params[:provider].present?

    @offset, @limit = api_offset_and_limit
    @mailbox_count = scope.count
    @mailboxes = scope.order(:mailbox_address => :asc).limit(@limit).offset(@offset)
    respond_to { |format| format.api }
  end

  def show
    respond_to { |format| format.api }
  end

  def create
    # project_id is deliberately not a safe attribute — the project comes from the
    # route, so a payload cannot move a mailbox into another project.
    @mailbox = HelpdeskMailbox.new(:project_id => @project.id)
    @mailbox.safe_attributes = params[:helpdesk_mailbox] || {}
    if @mailbox.save
      ensure_mailbox_folders
      respond_to { |format| format.api { render :action => 'show', :status => :created } }
    else
      render_validation_errors(@mailbox)
    end
  end

  def update
    @mailbox.safe_attributes = params[:helpdesk_mailbox] || {}
    if @mailbox.save
      ensure_mailbox_folders
      render_api_ok
    else
      render_validation_errors(@mailbox)
    end
  end

  def destroy
    @mailbox.destroy
    render_api_ok
  end

  # Probes the configured backend (IMAP or Graph) with the stored settings.
  # Unlike the UI variant this never merges submitted form state — the API works
  # on the persisted record only.
  def test_connection
    provider = RedmineExpertHelpdesk::MailProvider.for(@mailbox)
    unless provider.configured?
      @result = { :ok => false, :message => l(:error_helpdesk_provider_not_configured) }
      return respond_to { |format| format.api { render :action => 'test_connection', :status => :unprocessable_entity } }
    end

    @result = provider.test_connection
    respond_to { |format| format.api }
  rescue RedmineExpertHelpdesk::MailProvider::ProviderError => e
    @result = { :ok => false, :message => e.message }
    respond_to { |format| format.api { render :action => 'test_connection', :status => :unprocessable_entity } }
  end

  private

  # Mailboxes are addressed globally by id; the project comes from the record.
  def find_mailbox
    @mailbox = HelpdeskMailbox.find(params[:id])
    @project = @mailbox.project
  rescue ActiveRecord::RecordNotFound
    render_404
  end

  def require_helpdesk_module
    render_403 unless @project&.module_enabled?(:helpdesk)
  end

  # deny_access instead of a bare render_403: it answers 401 for an anonymous
  # caller and 403 only for one who is logged in but lacks the permission, which
  # is what the rest of the API (and Redmine core) does. A plain render_403 told
  # an unauthenticated client "forbidden" when the real answer was "authenticate".
  def authorize_manage
    deny_access unless User.current.allowed_to?(:manage_helpdesk, @project)
  end

  # Folder creation failures are reported by the UI as a flash warning; the API
  # just logs them — the mailbox itself saved fine and the error is visible again
  # via test_connection.
  def ensure_mailbox_folders
    error = RedmineExpertHelpdesk::MailboxFolders.ensure!(@mailbox)
    logger&.warn("Helpdesk: folder setup for mailbox #{@mailbox.id} failed: #{error}") if error
  end
end
