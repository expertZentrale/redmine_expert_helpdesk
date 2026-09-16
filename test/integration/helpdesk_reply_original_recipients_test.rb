require File.expand_path('../../test_helper', __FILE__)

# The reply form prefills To with the customer and leaves Cc empty, but the mail
# that opened the ticket was often addressed to several people. Those addresses
# are stored with every incoming mail, so the form offers them behind the To and
# Cc fields rather than making the agent reopen the original mail and retype
# them - which is what made them get dropped from the answer.
class HelpdeskReplyOriginalRecipientsTest < Redmine::IntegrationTest
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

    log_user('jsmith', 'jsmith') # Manager in project 1
  end

  def inbound(to, cc = nil)
    HelpdeskMessage.create!(:issue => @issue, :direction => 'in',
                            :recipient_to => to, :recipient_cc => cc)
  end

  # To offers the original To and Cc the original Cc: the customer's own
  # addressing is the best guess at who belongs where.
  def test_buttons_carry_the_original_recipients_per_field
    inbound('kunde@example.com, chef@kunde.de', 'kollege@kunde.de')
    get "/issues/#{@issue.id}/edit"

    assert_response :success
    assert_select 'span.hd-orig-wrap[data-hd-field="hd-to"][data-hd-original=?]',
                  ['chef@kunde.de'].to_json
    assert_select 'span.hd-orig-wrap[data-hd-field="hd-cc"][data-hd-original=?]',
                  ['kollege@kunde.de'].to_json
  end

  # The customer sits in the To field already, so offering them again is noise.
  # With nothing left to offer the button is absent rather than empty.
  def test_no_button_when_only_the_customer_was_addressed
    inbound('kunde@example.com')
    get "/issues/#{@issue.id}/edit"

    assert_response :success
    assert_select 'span.hd-orig-wrap', 0
  end

  def test_no_button_without_an_inbound_mail
    get "/issues/#{@issue.id}/edit"

    assert_response :success
    assert_select 'span.hd-orig-wrap', 0
  end

  # An inbound Bcc is stripped by the sending server, so there is nothing to
  # offer there and never will be.
  def test_bcc_never_gets_a_button
    inbound('kunde@example.com, chef@kunde.de', 'kollege@kunde.de')
    get "/issues/#{@issue.id}/edit"

    assert_response :success
    assert_select 'span.hd-orig-wrap[data-hd-field="hd-bcc"]', 0
  end
end
