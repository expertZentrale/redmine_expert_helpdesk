require File.expand_path('../../test_helper', __FILE__)

# "Status when replying" is a preselection, not a rule. The configured status is
# written into Redmine's own status select the moment "Send as email to customer"
# is ticked, so the agent still sees it and can pick something else - typically a
# "waiting for the customer" status that takes the ticket out of the open list.
# It used to be forced into the select inside the send callback, one statement
# before issueForm.submit(), where nobody could see or change it.
class HelpdeskReplyStatusTest < Redmine::IntegrationTest
  fixtures :projects, :users, :email_addresses, :members, :member_roles, :roles,
           :enabled_modules, :trackers, :projects_trackers, :issue_statuses,
           :enumerations, :issues

  def setup
    @project = Project.find(1)
    @project.enable_module!(:helpdesk)
    Role.find(1).add_permission!(:manage_helpdesk, :send_helpdesk_reply, :view_helpdesk_info)

    # The reply block is only rendered for a ticket that has a customer contact.
    HelpdeskContact.where(:project_id => @project.id).delete_all
    @contact = HelpdeskContact.create!(:project_id => @project.id,
                                       :email => 'kunde@example.com', :name => 'Kunde')
    @issue = Issue.find(1)
    HelpdeskTicketInfo.create!(:issue_id => @issue.id, :helpdesk_contact_id => @contact.id)

    @status = IssueStatus.where(:is_closed => false).first
    log_user('jsmith', 'jsmith') # Manager in project 1
  end

  def set_reply_status(status_id)
    HelpdeskProjectSetting.for_project(@project).update!(:reply_status_id => status_id)
  end

  # --- The preselect the form carries ------------------------------------

  def test_reply_section_carries_the_configured_status
    set_reply_status(@status.id)
    get "/issues/#{@issue.id}/edit"

    assert_response :success
    assert_select '#hd-reply-section[data-hd-reply-status=?]', @status.id.to_s
  end

  def test_reply_section_carries_no_status_when_none_is_configured
    set_reply_status(nil)
    get "/issues/#{@issue.id}/edit"

    assert_response :success
    assert_select '#hd-reply-section[data-hd-reply-status=""]'
  end

  def test_assign_to_sender_is_carried_the_same_way
    HelpdeskProjectSetting.for_project(@project).update!(:reply_assign_to_sender => true)
    get "/issues/#{@issue.id}/edit"

    assert_response :success
    assert_select '#hd-reply-section[data-hd-assign-to-sender="1"]'
    assert_select '#hd-reply-section[data-hd-current-user=?]', User.find_by_login('jsmith').id.to_s
  end

  # Regression pin. The forced version interpolated the id as a literal
  # ("statusSel.value = '3';"); the preselect assigns a variable. Should this
  # ever fail after a rename, check that the assignment still happens on the
  # checkbox toggle and not in the send callback - do not just widen the regex.
  def test_status_is_not_forced_into_the_select_at_submit_time
    set_reply_status(@status.id)
    get "/issues/#{@issue.id}/edit"

    assert_response :success
    assert_no_match(/statusSel\.value = '\d+'/, response.body)
  end

  # Redmine's own inline script on the issue page resets tracker and status to
  # the server-rendered option in a $(document).ready callback - its defence
  # against the browser restoring a stale form state. That callback outlives both
  # DOMContentLoaded and window load, so applying the preselection from either
  # one alone is silently undone and the agent sees the old status on page load.
  # Queueing it through jQuery, which runs ready callbacks in registration order
  # and reaches this partial last, is what makes it stick. Pin it: nothing else
  # in the suite would notice it being "simplified" back.
  def test_preselect_is_queued_after_redmines_own_ready_callback
    set_reply_status(@status.id)
    get "/issues/#{@issue.id}/edit"

    assert_response :success

    # Core's reset, app/views/issues/_form.html.erb - unchanged in 5.1 .. 7.0:
    #   $(document).ready(function(){
    #     $("#issue_tracker_id, #issue_status_id").each(function(){
    #       $(this).val($(this).find("option[selected=selected]").val()); }); ... });
    core = response.body.index('$("#issue_tracker_id, #issue_status_id")')
    assert core, 'Redmine no longer resets the status select on ready - if that is ' \
                 'really gone, the jQuery-ready detour here can go with it'

    ours = response.body.index('window.jQuery(applyInitialReplyDefaults)')
    assert ours, 'the preselect is no longer queued through the jQuery ready queue'

    # The order is the whole point: jQuery runs ready callbacks in registration
    # order, so ours only wins by being registered later in the document.
    assert core < ours,
           'the reply preselect must be registered after core\'s reset, otherwise ' \
           'the agent sees the old status on page load'
  end

  # --- The project setting behind it -------------------------------------

  def test_reply_status_round_trips_through_the_settings_form
    put helpdesk_project_setting_path(:project_id => @project),
        :params => { :helpdesk_project_setting => { :reply_status_id => @status.id.to_s } }
    assert_equal @status.id, HelpdeskProjectSetting.for_project(@project).reload.reply_status_id

    put helpdesk_project_setting_path(:project_id => @project),
        :params => { :helpdesk_project_setting => { :reply_status_id => '' } }
    assert_nil HelpdeskProjectSetting.for_project(@project).reload.reply_status_id
  end

  # Deliberately unlike the info-request status, which offers open statuses only:
  # that one is applied automatically and a closed status would mark both SLA
  # clocks met behind the customer's back. This one is only ever applied by an
  # agent saving the ticket form, and "close while waiting for the customer" is
  # exactly what it is for.
  def test_settings_select_offers_closed_statuses_too
    closed = IssueStatus.where(:is_closed => true).first
    assert closed, 'fixtures should contain a closed status'

    get settings_project_path(@project, :tab => 'expert_helpdesk')

    assert_response :success
    assert_select 'select#hd_reply_status_id' do
      assert_select 'option[value=?]', closed.id.to_s, :text => closed.name
      assert_select 'option[value=?]', @status.id.to_s, :text => @status.name
    end
  end
end
