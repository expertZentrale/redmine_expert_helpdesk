require File.expand_path('../../test_helper', __FILE__)

# The reply form and endpoint with the experimental hand-over switched on: a
# participating project's helpdesk address is taken out of the mail, the agent
# has to choose what goes over, and the ticket is created there directly.
class HelpdeskHandoverReplyTest < Redmine::IntegrationTest
  fixtures :projects, :users, :email_addresses, :members, :member_roles, :roles,
           :enabled_modules, :trackers, :projects_trackers, :issue_statuses,
           :enumerations, :issues, :journals, :attachments

  # Stands in for the outgoing transport and keeps what it was asked to send.
  class FakeTransport
    attr_reader :sent

    def initialize(fail_with: nil)
      @sent = []
      @fail_with = fail_with
    end

    def send_mail_mime(mime)
      raise @fail_with if @fail_with

      @sent << mime
    end

    def method_missing(*); nil; end

    def respond_to_missing?(*); true; end
  end

  def setup
    @settings_before = Setting.plugin_redmine_expert_helpdesk
    Setting.plugin_redmine_expert_helpdesk = @settings_before.merge('handover_enabled' => '1')
    Setting.cross_project_issue_relations = '1'

    @project = Project.find(1)
    @other   = Project.find(2)
    [@project, @other].each do |p|
      p.enable_module!(:helpdesk)
      HelpdeskProjectSetting.for_project(p).tap { |s| s.handover_enabled = true }.save!
    end
    Role.find(1).add_permission!(:manage_helpdesk, :send_helpdesk_reply, :view_helpdesk_info)

    @mailbox = HelpdeskMailbox.create!(:project => @project, :mailbox_address => 'helpdesk-a@expert.local',
                                       :provider => 'imap', :imap_host => 'mail.example.com',
                                       :smtp_host => 'mail.example.com', :reply_transport => 'provider')
    @target = HelpdeskMailbox.create!(:project => @other, :mailbox_address => 'helpdesk-b@expert.local',
                                      :provider => 'imap', :imap_host => 'mail.example.com')

    HelpdeskContact.where(:project_id => @project.id).delete_all
    @contact = HelpdeskContact.create!(:project_id => @project.id, :email => 'kunde@example.com', :name => 'Kunde')
    @issue = Issue.find(1)
    HelpdeskTicketInfo.where(:issue_id => @issue.id).delete_all
    HelpdeskTicketInfo.create!(:issue_id => @issue.id, :helpdesk_contact_id => @contact.id,
                               :helpdesk_mailbox_id => @mailbox.id)

    log_user('jsmith', 'jsmith')
  end

  def teardown
    Setting.plugin_redmine_expert_helpdesk = @settings_before
  end

  def reply(params)
    post "/issues/#{@issue.id}/helpdesk_reply", :params => { :note_content => 'Bitte uebernehmen' }.merge(params)
    JSON.parse(response.body)
  end

  def other_project_tickets
    Issue.where(:project_id => @other.id)
  end

  # --- form -----------------------------------------------------------------

  def test_form_offers_the_participating_address
    get "/issues/#{@issue.id}/edit"

    assert_response :success
    assert_select 'tr#hd-handover[data-hd-targets*=?]', 'helpdesk-b@expert.local'
    assert_select 'input[name=hd_handover_mode]', 2
    assert_select 'input[name=hd_handover_mode][checked]', 0
  end

  def test_form_without_the_central_switch_has_no_handover
    Setting.plugin_redmine_expert_helpdesk = @settings_before.merge('handover_enabled' => '0')
    get "/issues/#{@issue.id}/edit"

    assert_response :success
    assert_select 'tr#hd-handover', 0
  end

  # --- endpoint ---------------------------------------------------------------

  def test_a_choice_is_required
    before = other_project_tickets.count
    data = reply(:reply_to => 'helpdesk-b@expert.local')

    assert_response :unprocessable_entity
    assert_not data['success']
    assert_equal before, other_project_tickets.count
  end

  # Only the other project addressed: nothing is mailed at all.
  def test_handover_only_sends_no_mail
    RedmineExpertHelpdesk::MailProvider.expects(:outgoing_for).never
    data = reply(:reply_to => 'helpdesk-b@expert.local', :handover_mode => 'note')

    assert_response :success
    assert data['success']
    created = Issue.find(data['handovers'].first['issue_id'])
    assert_equal @other, created.project
    assert_equal 'helpdesk-b@expert.local', data['handovers'].first['address']
  end

  # Customer in To, other project in Cc: the customer is mailed without the Cc.
  def test_customer_still_gets_the_mail_without_the_handover_address
    transport = FakeTransport.new
    RedmineExpertHelpdesk::MailProvider.stubs(:outgoing_for).returns(transport)
    data = reply(:reply_to => 'kunde@example.com', :reply_cc => 'helpdesk-b@expert.local',
                 :handover_mode => 'history')

    assert_response :success
    assert data['helpdesk_message_id']
    assert_equal 1, transport.sent.size
    assert_includes transport.sent.first, 'kunde@example.com'
    assert_not_includes transport.sent.first, 'helpdesk-b@expert.local'
    assert_equal 1, data['handovers'].size
  end

  # A failed mail takes the hand-over back, so sending again creates no twin.
  def test_failed_mail_undoes_the_handover
    RedmineExpertHelpdesk::MailProvider.stubs(:outgoing_for)
      .returns(FakeTransport.new(:fail_with => RedmineExpertHelpdesk::MailProvider::ProviderError.new('SMTP down')))
    before = other_project_tickets.count
    data = reply(:reply_to => 'kunde@example.com', :reply_cc => 'helpdesk-b@expert.local',
                 :handover_mode => 'note')

    assert_response :unprocessable_entity
    assert_not data['success']
    assert_equal before, other_project_tickets.count
  end

  # --- several recipients -----------------------------------------------------

  def third_project
    project = Project.find(3)
    project.enable_module!(:helpdesk)
    HelpdeskProjectSetting.for_project(project).tap { |s| s.handover_enabled = true }.save!
    HelpdeskMailbox.create!(:project => project, :mailbox_address => 'helpdesk-c@expert.local',
                            :provider => 'imap', :imap_host => 'mail.example.com')
    project
  end

  # Two projects in Cc: a ticket in each, the customer still gets the mail.
  def test_two_target_projects_get_a_ticket_each
    project_c = third_project
    transport = FakeTransport.new
    RedmineExpertHelpdesk::MailProvider.stubs(:outgoing_for).returns(transport)
    data = reply(:reply_to => 'kunde@example.com',
                 :reply_cc => 'helpdesk-b@expert.local, "Team C" <helpdesk-c@expert.local>',
                 :handover_mode => 'note')

    assert_response :success
    projects = data['handovers'].map { |h| Issue.find(h['issue_id']).project }
    assert_equal [@other, project_c].map(&:id).sort, projects.map(&:id).sort
    assert_equal 1, transport.sent.size
    assert_not_includes transport.sent.first, 'helpdesk-c@expert.local'
  end

  # The same target named twice, in another spelling: one ticket.
  def test_same_target_twice_is_one_handover
    RedmineExpertHelpdesk::MailProvider.stubs(:outgoing_for).returns(FakeTransport.new)
    data = reply(:reply_to => 'kunde@example.com', :reply_cc => 'helpdesk-b@expert.local',
                 :reply_bcc => 'Helpdesk-B@Expert.local', :handover_mode => 'note')

    assert_equal 1, Array(data['handovers']).size, data.inspect
  end

  # Two mailboxes of one project: the project gets one ticket, not two.
  def test_two_mailboxes_of_one_project_are_one_handover
    HelpdeskMailbox.create!(:project => @other, :mailbox_address => 'helpdesk-b2@expert.local',
                            :provider => 'imap', :imap_host => 'mail.example.com')
    before = other_project_tickets.count
    data = reply(:reply_to => 'helpdesk-b@expert.local', :reply_cc => 'helpdesk-b2@expert.local',
                 :handover_mode => 'note')

    assert_response :success
    assert_equal 1, data['handovers'].size
    assert_equal before + 1, other_project_tickets.count
  end

  # Target in To, customer in Cc: the customer moves up to To.
  def test_cc_moves_to_to_when_only_targets_were_in_to
    transport = FakeTransport.new
    RedmineExpertHelpdesk::MailProvider.stubs(:outgoing_for).returns(transport)
    reply(:reply_to => 'helpdesk-b@expert.local', :reply_cc => 'kunde@example.com', :handover_mode => 'note')

    assert_response :success
    mail = Mail.read_from_string(transport.sent.first)
    assert_equal ['kunde@example.com'], mail.to
    assert_empty Array(mail.cc)
  end

  # Only a Bcc left: a mail with no visible recipient is refused, and
  # nothing is handed over either.
  def test_only_bcc_left_is_refused_before_anything_happens
    RedmineExpertHelpdesk::MailProvider.expects(:outgoing_for).never
    before = other_project_tickets.count
    data = reply(:reply_to => 'helpdesk-b@expert.local', :reply_bcc => 'chef@example.com',
                 :handover_mode => 'note')

    assert_response :unprocessable_entity
    assert_not data['success']
    assert_equal before, other_project_tickets.count
  end

  # Without the hand-over the address is an ordinary recipient, as before.
  def test_switched_off_the_address_is_mailed
    HelpdeskProjectSetting.for_project(@other).update!(:handover_enabled => false)
    transport = FakeTransport.new
    RedmineExpertHelpdesk::MailProvider.stubs(:outgoing_for).returns(transport)
    data = reply(:reply_to => 'kunde@example.com', :reply_cc => 'helpdesk-b@expert.local')

    assert_response :success
    assert_includes transport.sent.first, 'helpdesk-b@expert.local'
    assert_empty Array(data['handovers'])
  end
end
