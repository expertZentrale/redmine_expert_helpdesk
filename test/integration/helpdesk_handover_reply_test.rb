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

    def initialize(fail_with: nil, before_fail: nil)
      @sent = []
      @fail_with = fail_with
      @before_fail = before_fail
    end

    def send_mail_mime(mime)
      @before_fail&.call
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

  # The other team answered on the new ticket while the mail was still being
  # sent: taking the hand-over back would delete their answer. It stays, is
  # final, and the agent is told to leave its address out next time.
  def test_failed_mail_keeps_a_handover_someone_worked_on
    worked_on = lambda do
      ticket = other_project_tickets.order(:id).last
      ticket.init_journal(User.find(3), 'Wir kuemmern uns')
      ticket.save(:validate => false)
    end
    RedmineExpertHelpdesk::MailProvider.stubs(:outgoing_for).returns(
      FakeTransport.new(:fail_with => RedmineExpertHelpdesk::MailProvider::ProviderError.new('SMTP down'),
                        :before_fail => worked_on)
    )
    RedmineExpertHelpdesk::Handover.expects(:finalize).once
    before = other_project_tickets.count
    data = reply(:reply_to => 'kunde@example.com', :reply_cc => 'helpdesk-b@expert.local', :handover_mode => 'note')

    assert_response :unprocessable_entity
    kept = other_project_tickets.order(:id).last
    assert_equal before + 1, other_project_tickets.count
    assert_includes kept.journals.map(&:notes), 'Wir kuemmern uns'
    assert_includes data['error'], 'SMTP down'
    assert_includes data['error'], "##{kept.id}"
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

  # Delivered, then the bookkeeping fails: the hand-over stays and the reply
  # counts as sent, so the agent does not mail the customer twice.
  def test_failure_after_delivery_keeps_the_handover
    transport = FakeTransport.new
    RedmineExpertHelpdesk::MailProvider.stubs(:outgoing_for).returns(transport)
    RedmineExpertHelpdesk::Sla.stubs(:record_first_response!).raises(RuntimeError, 'SLA down')
    before = other_project_tickets.count
    data = reply(:reply_to => 'kunde@example.com', :reply_cc => 'helpdesk-b@expert.local',
                 :handover_mode => 'note')

    assert_response :success
    assert data['success']
    assert data['warning']
    assert_equal 1, transport.sent.size
    assert_equal before + 1, other_project_tickets.count
  end

  # To cleared on purpose, only the other project in Cc: a hand-over without
  # a mail, not a mail to the customer.
  def test_cleared_to_with_handover_mails_nobody
    RedmineExpertHelpdesk::MailProvider.expects(:outgoing_for).never
    data = reply(:reply_to => '', :reply_cc => 'helpdesk-b@expert.local', :handover_mode => 'note')

    assert_response :success
    assert_equal 1, data['handovers'].size
  end

  # The receiving project's default assignee takes the ticket, as for mail.
  def test_handover_uses_the_target_default_assignee
    agent = User.find(3)
    Member.create!(:principal => agent, :project => @other, :role_ids => [1]) unless agent.member_of?(@other)
    HelpdeskProjectSetting.for_project(@other).update!(:default_assigned_to_id => agent.id)
    RedmineExpertHelpdesk::MailProvider.expects(:outgoing_for).never
    data = reply(:reply_to => 'helpdesk-b@expert.local', :handover_mode => 'note')

    assert_equal agent, Issue.find(data['handovers'].first['issue_id']).assigned_to
  end

  # A target named in Bcc only is flagged, so the form keeps it out of a
  # public note.
  def test_bcc_only_target_is_flagged
    RedmineExpertHelpdesk::MailProvider.stubs(:outgoing_for).returns(FakeTransport.new)
    data = reply(:reply_to => 'kunde@example.com', :reply_bcc => 'helpdesk-b@expert.local',
                 :handover_mode => 'note')

    assert_response :success
    assert_equal true, data['handovers'].first['bcc']
    created = data['handovers'].first['issue_id']
    assert_not IssueRelation.where(:issue_from_id => [created, @issue.id], :issue_to_id => [created, @issue.id]).exists?,
               'a relation would show who got it by Bcc'
  end

  def test_target_in_cc_is_not_flagged
    RedmineExpertHelpdesk::MailProvider.stubs(:outgoing_for).returns(FakeTransport.new)
    data = reply(:reply_to => 'kunde@example.com', :reply_cc => 'helpdesk-b@expert.local',
                 :handover_mode => 'note')

    assert_equal false, data['handovers'].first['bcc']
    created = data['handovers'].first['issue_id']
    assert IssueRelation.where(:issue_from_id => [created, @issue.id], :issue_to_id => [created, @issue.id]).exists?
  end

  # A hand-over copies the ticket out; an agent who may not read it gets 403.
  def test_handover_needs_a_visible_source_ticket
    Issue.any_instance.stubs(:visible?).returns(false)
    before = other_project_tickets.count
    reply(:reply_to => 'helpdesk-b@expert.local', :handover_mode => 'history')

    assert_response :forbidden
    assert_equal before, other_project_tickets.count
  end

  # A ticket image the note quotes goes along, checked or not.
  def test_quoted_ticket_image_is_handed_over
    set_tmp_attachments_directory
    image = Attachment.create!(:container => @issue, :author => User.find(2), :filename => 'shot.png',
                               :content_type => 'image/png',
                               :file => uploaded_test_file('testfile.txt', 'image/png'))
    with_settings :text_formatting => 'textile' do
      data = reply(:note_content => "Siehe !/attachments/download/#{image.id}/shot.png!",
                   :reply_to => 'helpdesk-b@expert.local', :handover_mode => 'note')
      created = Issue.find(data['handovers'].first['issue_id'])
      # The only file handed over; its name comes from the uploaded test file.
      copy = created.attachments.detect { |a| a.digest == image.digest }

      assert copy, 'quoted image not handed over'
      assert_includes created.description, "/attachments/download/#{copy.id}/"
      assert_not_includes created.description, "/attachments/download/#{image.id}/"
    end
  end

  # No notification about a hand-over that a failed mail takes back again.
  def test_failed_mail_sends_no_handover_notification
    RedmineExpertHelpdesk::MailProvider.stubs(:outgoing_for)
      .returns(FakeTransport.new(:fail_with => RedmineExpertHelpdesk::MailProvider::ProviderError.new('SMTP down')))
    RedmineExpertHelpdesk::Handover.expects(:notify).never
    reply(:reply_to => 'kunde@example.com', :reply_cc => 'helpdesk-b@expert.local', :handover_mode => 'note')

    assert_response :unprocessable_entity
  end

  def test_delivered_handover_is_notified
    RedmineExpertHelpdesk::MailProvider.stubs(:outgoing_for).returns(FakeTransport.new)
    RedmineExpertHelpdesk::Handover.expects(:notify).once
    reply(:reply_to => 'kunde@example.com', :reply_cc => 'helpdesk-b@expert.local', :handover_mode => 'note')

    assert_response :success
  end

  # "Last ticket" in the customer list: cell and sort agree, and a hand-over
  # counts although the contact has no mail in the target project yet.
  def last_ticket(contact)
    [contact.last_ticket_at,
     HelpdeskContact.where(:id => contact.id).pick(Arel.sql(HelpdeskContactsController::LAST_TICKET_SQL))]
  end

  def test_handover_only_contact_has_a_last_ticket_date
    data = reply(:reply_to => 'helpdesk-b@expert.local', :handover_mode => 'note')
    created = Issue.find(data['handovers'].first['issue_id'])
    contact = HelpdeskContact.find_by(:project_id => @other.id, :email => 'kunde@example.com')
    cell, sorted = last_ticket(contact)

    assert_equal created.created_on.to_i, cell.to_i
    assert_equal created.created_on.to_i, sorted.to_time.to_i
  end

  def test_last_ticket_date_takes_a_newer_handover_over_an_older_mail
    contact = HelpdeskContact.create!(:project_id => @other.id, :email => 'kunde@example.com', :name => 'Kunde')
    HelpdeskMessage.create!(:issue => Issue.where(:project_id => @other.id).first, :helpdesk_contact => contact,
                            :direction => 'in', :sent_at => 10.days.ago)
    data = reply(:reply_to => 'helpdesk-b@expert.local', :handover_mode => 'note')
    created = Issue.find(data['handovers'].first['issue_id'])
    cell, sorted = last_ticket(contact.reload)

    assert_equal created.created_on.to_i, cell.to_i
    assert_equal created.created_on.to_i, sorted.to_time.to_i
  end

  def test_customer_list_shows_the_date_of_a_handover_only_contact
    reply(:reply_to => 'helpdesk-b@expert.local', :handover_mode => 'note')
    Role.find(2).add_permission!(:manage_helpdesk_contacts)
    get "/projects/#{@other.identifier}/helpdesk_contacts"

    assert_response :success
    assert_select 'table.list tbody tr', :text => /kunde@example.com/ do
      assert_select 'td:nth-child(6)', :text => /\d/
    end
  end

  # The customer's contact in the target project lists the handed-over
  # ticket before any mail of theirs reached it.
  def test_handed_over_ticket_is_in_the_target_contact_history
    data = reply(:reply_to => 'helpdesk-b@expert.local', :handover_mode => 'note')
    created = Issue.find(data['handovers'].first['issue_id'])
    contact = HelpdeskContact.find_by(:project_id => @other.id, :email => 'kunde@example.com')

    admin = User.find(1)
    assert_includes contact.issues(admin).to_a, created
    # The list's sortable ticket count counts it too.
    count = HelpdeskContact.where(:id => contact.id)
                           .pick(Arel.sql(HelpdeskContactsController::TICKET_COUNT_SQL))
    assert_equal contact.issues(admin).count, count.to_i
  end

  # The contact is itself a participating mailbox and To is cleared: only
  # the project the agent named in Cc gets a ticket.
  def test_cleared_to_does_not_hand_over_to_the_contact
    project_c = third_project
    @contact.update_column(:email, 'helpdesk-b@expert.local')
    RedmineExpertHelpdesk::MailProvider.expects(:outgoing_for).never
    data = reply(:reply_to => '', :reply_cc => 'helpdesk-c@expert.local', :handover_mode => 'note')

    assert_response :success
    assert_equal [project_c.id], data['handovers'].map { |h| Issue.find(h['issue_id']).project_id }
  end

  # A rewritten image link, then the mail fails: the hand-over is still
  # taken back (the reload keeps lock_version current for the destroy).
  def test_failed_mail_undoes_a_handover_with_rewritten_images
    set_tmp_attachments_directory
    image = Attachment.create!(:container => @issue, :author => User.find(2), :filename => 'shot.png',
                               :content_type => 'image/png',
                               :file => uploaded_test_file('testfile.txt', 'image/png'))
    RedmineExpertHelpdesk::MailProvider.stubs(:outgoing_for)
      .returns(FakeTransport.new(:fail_with => RedmineExpertHelpdesk::MailProvider::ProviderError.new('SMTP down')))
    before = other_project_tickets.count
    with_settings :text_formatting => 'textile' do
      reply(:note_content => "Siehe !/attachments/download/#{image.id}/shot.png!",
            :reply_to => 'kunde@example.com', :reply_cc => 'helpdesk-b@expert.local', :handover_mode => 'note')
    end

    assert_response :unprocessable_entity
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
