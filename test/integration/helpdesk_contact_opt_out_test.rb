require File.expand_path('../../test_helper', __FILE__)

# "Never ask this customer for more information": the flag an agent sets on the
# contact itself, instead of asking an admin to extend the project-wide sender
# list. Covers the form round-trip and the marker in the customer list - what an
# ERB syntax check cannot see.
class HelpdeskContactOptOutTest < Redmine::IntegrationTest
  fixtures :projects, :users, :email_addresses, :members, :member_roles, :roles,
           :enabled_modules, :trackers, :projects_trackers, :issue_statuses,
           :enumerations, :issues

  def setup
    @project = Project.find(1)
    @project.enable_module!(:helpdesk)
    Role.find(1).add_permission!(:manage_helpdesk_contacts)
    HelpdeskContact.where(:project_id => @project.id).delete_all
    @contact = HelpdeskContact.create!(:project_id => @project.id,
                                       :email => 'veeam@example.com', :name => 'Veeam')
    # The header bar renders off the ticket's contact link, not off the issue alone.
    @issue = Issue.find(1)
    HelpdeskTicketInfo.create!(:issue_id => @issue.id, :helpdesk_contact_id => @contact.id)
    Role.find(1).add_permission!(:view_helpdesk_info)
    log_user('jsmith', 'jsmith')
  end

  def test_edit_form_offers_the_checkbox
    get "/projects/#{@project.identifier}/helpdesk_contacts/#{@contact.id}/edit"

    assert_response :success
    assert_select 'input[type=checkbox][name=?]', 'helpdesk_contact[info_request_opt_out]'
  end

  def test_agent_can_set_and_clear_the_flag
    put "/projects/#{@project.identifier}/helpdesk_contacts/#{@contact.id}",
        :params => { :helpdesk_contact => { :info_request_opt_out => '1' } }
    assert_response :redirect
    assert_equal true, @contact.reload.info_request_opt_out?

    put "/projects/#{@project.identifier}/helpdesk_contacts/#{@contact.id}",
        :params => { :helpdesk_contact => { :info_request_opt_out => '0' } }
    assert_response :redirect
    assert_equal false, @contact.reload.info_request_opt_out?
  end

  # The toggle an agent actually reaches: on the ticket, not in the customer list.
  def test_toggle_from_the_ticket_flips_the_flag_and_returns_to_the_ticket
    post "/projects/#{@project.identifier}/helpdesk_contacts/#{@contact.id}/toggle_info_request",
         :params => { :back_url => "/issues/#{@issue.id}" }
    assert_redirected_to "/issues/#{@issue.id}"
    assert_equal true, @contact.reload.info_request_opt_out?

    post "/projects/#{@project.identifier}/helpdesk_contacts/#{@contact.id}/toggle_info_request",
         :params => { :back_url => "/issues/#{@issue.id}" }
    assert_redirected_to "/issues/#{@issue.id}"
    assert_equal false, @contact.reload.info_request_opt_out?
  end

  # An agent's decision has to be datable afterwards - the contact API hands out
  # updated_on, and a flag written past the timestamp is invisible there.
  def test_toggle_updates_the_timestamp
    @contact.update_columns(:updated_at => 3.days.ago)
    before = @contact.reload.updated_at

    post "/projects/#{@project.identifier}/helpdesk_contacts/#{@contact.id}/toggle_info_request"

    assert @contact.reload.updated_at > before,
           'toggling the flag must bump updated_at'
  end

  # Reading the customer info is not permission enough to change this.
  def test_toggle_denied_without_manage_permission
    Role.find(1).remove_permission!(:manage_helpdesk_contacts)
    post "/projects/#{@project.identifier}/helpdesk_contacts/#{@contact.id}/toggle_info_request"
    assert_response :forbidden
    assert_equal false, @contact.reload.info_request_opt_out?
  end

  # The link is offered on the ticket only while the check can run there, and only
  # to agents who may edit contacts.
  def test_ticket_header_offers_the_toggle_only_when_the_check_runs
    with_plugin_setting('info_request_enabled' => '1') do
      HelpdeskProjectSetting.for_project(@project).update!(:info_request_mode => 'heuristic')
      get "/issues/#{@issue.id}"
      assert_response :success
      assert_select 'a.icon-email-disabled.hih-optout-toggle',
                    :text => "(#{I18n.t(:button_helpdesk_contact_info_request_stop)})"

      HelpdeskProjectSetting.for_project(@project).update!(:info_request_mode => 'off')
      get "/issues/#{@issue.id}"
      assert_select 'a.hih-optout-toggle', :count => 0
    end
  end

  # An already flagged customer keeps the undo link even when the check is off, so
  # the state stays reversible where it was set.
  def test_flagged_ticket_header_shows_marker_and_undo
    @contact.update!(:info_request_opt_out => true)
    with_plugin_setting('info_request_enabled' => '0') do
      get "/issues/#{@issue.id}"
      assert_response :success
      assert_select 'span.hih-addr-tag',
                    :text => I18n.t(:label_helpdesk_contact_info_request_opt_out_short)
      assert_select 'a.icon-email.hih-optout-toggle',
                    :text => "(#{I18n.t(:button_helpdesk_contact_info_request_resume)})"
    end
  end

  # Without the marker a flagged customer looks like every other one, and the
  # missing follow-up looks like a broken check.
  def test_customer_list_marks_flagged_contacts_only
    get "/projects/#{@project.identifier}/helpdesk_contacts"
    assert_response :success
    assert_select 'span.hd-contact-tag', :count => 0

    @contact.update!(:info_request_opt_out => true)
    get "/projects/#{@project.identifier}/helpdesk_contacts"
    assert_response :success
    assert_select 'span.hd-contact-tag',
                  :text => I18n.t(:label_helpdesk_contact_info_request_opt_out_short)
  end

  private

  def with_plugin_setting(hash)
    original = Setting.plugin_redmine_expert_helpdesk
    Setting.plugin_redmine_expert_helpdesk = original.merge(hash)
    yield
  ensure
    Setting.plugin_redmine_expert_helpdesk = original
  end
end
