require File.expand_path('../../test_helper', __FILE__)

# The initial mail of a new ticket ("New helpdesk ticket") and of the
# "assign contact" form with the experimental hand-over switched on: a
# participating project's helpdesk address leaves the mail and gets the ticket
# directly, carrying what the mail would have carried. Nothing to choose here,
# and without a customer in To nothing goes out at all.
class HelpdeskInitHandoverTest < Redmine::IntegrationTest
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
    HelpdeskContact.where(:project_id => [@project.id, @other.id]).delete_all

    log_user('jsmith', 'jsmith')
  end

  def teardown
    Setting.plugin_redmine_expert_helpdesk = @settings_before
  end

  def transport(**opts)
    FakeTransport.new(**opts).tap { |t| RedmineExpertHelpdesk::MailProvider.stubs(:outgoing_for).returns(t) }
  end

  # "New helpdesk ticket": the issue form with the helpdesk fields.
  def create_ticket(helpdesk)
    helpdesk = helpdesk.dup
    subject  = helpdesk.delete(:subject) || 'Drucker defekt'
    post '/projects/ecookbook/issues', :params => {
      :issue         => { :tracker_id => 1, :subject => subject, :description => 'Bitte pruefen',
                          :priority_id => 5 },
      :helpdesk_init => { :send_mail => '1', :mailbox_id => @mailbox.id.to_s }.merge(helpdesk)
    }
    Issue.where(:project_id => @project.id).order(:id).last
  end

  def handed_over
    Issue.where(:project_id => @other.id).order(:id).last
  end

  def other_count
    Issue.where(:project_id => @other.id).count
  end

  def customer_of(issue)
    HelpdeskTicketInfo.for_issue(issue)&.helpdesk_contact&.email
  end

  # --- form -----------------------------------------------------------------

  def test_form_knows_the_participating_address
    get '/projects/ecookbook/issues/new'

    assert_response :success
    assert_select '#hd-init-status[data-hd-targets*=?]', 'helpdesk-b@expert.local'
    assert_select 'input#hd-init-move-cc[name=?]', 'helpdesk_init[move_cc]'
  end

  # Rendered again (here: the ticket did not validate), the form keeps what
  # the agent typed instead of coming back empty.
  def test_form_keeps_the_helpdesk_fields_when_rendered_again
    post '/projects/ecookbook/issues', :params => {
      :issue         => { :tracker_id => 1, :subject => '', :priority_id => 5 },
      :helpdesk_init => { :send_mail => '1', :contact_email => 'kunde@example.com',
                          :cc => 'helpdesk-b@expert.local', :move_cc => '1' }
    }

    assert_select 'input#hd-init-send-cb[checked]'
    assert_select 'input#hd-init-to[value=?]', 'kunde@example.com'
    assert_select 'input#hd-init-cc[value=?]', 'helpdesk-b@expert.local'
    assert_select 'input#hd-init-move-cc[checked]'
  end

  # --- new ticket -------------------------------------------------------------

  def test_customer_is_mailed_and_the_other_project_gets_the_ticket
    t = transport
    RedmineExpertHelpdesk::Handover.expects(:notify).once
    before = other_count
    issue = create_ticket(:contact_email => 'kunde@example.com', :cc => 'helpdesk-b@expert.local')

    assert_equal 1, t.sent.size
    assert_includes t.sent.first, 'kunde@example.com'
    assert_not_includes t.sent.first, 'helpdesk-b@expert.local'
    assert_equal before + 1, other_count
    created = handed_over
    assert_equal 'Drucker defekt', created.subject
    assert_includes created.description, 'Bitte pruefen'
    assert_equal @target.id, HelpdeskTicketInfo.for_issue(created).handover_mailbox_id
    assert_equal 'kunde@example.com', customer_of(created)
    # Redmine stores a "relates" relation with the lower id first.
    assert IssueRelation.where(:issue_from_id => [created.id, issue.id], :issue_to_id => [created.id, issue.id]).exists?
    assert_equal 'kunde@example.com', customer_of(issue)
    note = issue.journals.where.not(:notes => [nil, '']).last
    assert_includes note.notes, "##{created.id}"
    assert_not note.private_notes
  end

  # Only the other project named: nothing is mailed, and its mailbox does not
  # become this ticket's customer.
  def test_handover_only_mails_nobody_and_assigns_no_customer
    RedmineExpertHelpdesk::MailProvider.expects(:outgoing_for).never
    before = other_count
    issue = create_ticket(:contact_email => 'helpdesk-b@expert.local')

    assert_equal before + 1, other_count
    assert_nil customer_of(issue)
    assert_equal 0, HelpdeskMessage.where(:issue_id => issue.id).count
    assert_equal 0, HelpdeskContact.where(:email => 'helpdesk-b@expert.local').count
    assert_nil flash[:error]
  end

  # Customer only in Cc: without the agent's word nothing happens, and the
  # next page says so.
  def test_no_customer_in_to_sends_and_hands_over_nothing
    RedmineExpertHelpdesk::MailProvider.expects(:outgoing_for).never
    before = other_count
    issue = create_ticket(:contact_email => 'helpdesk-b@expert.local', :cc => 'kunde@example.com',
                          :subject => 'Ohne Kunde')

    assert_equal 'Ohne Kunde', issue.subject, 'the ticket itself is still created'
    assert_equal before, other_count
    assert_nil customer_of(issue)
    assert_equal ERB::Util.h(I18n.t(:error_helpdesk_init_no_to)), flash[:error]
  end

  def test_moving_the_first_cc_makes_it_the_customer
    t = transport
    before = other_count
    issue = create_ticket(:contact_email => 'helpdesk-b@expert.local',
                          :cc => 'kunde@example.com, chef@example.com', :move_cc => '1')

    assert_equal before + 1, other_count
    assert_equal 'kunde@example.com', customer_of(issue)
    assert_match(/^To: kunde@example.com\r?$/, t.sent.first)
    assert_match(/^Cc: chef@example.com\r?$/, t.sent.first)
  end

  # A comma inside a quoted display name or local part separates nothing.
  def test_quoted_display_name_of_the_other_project_is_one_recipient
    RedmineExpertHelpdesk::MailProvider.expects(:outgoing_for).never
    before = other_count
    create_ticket(:contact_email => '"Team, B" <helpdesk-b@expert.local>')

    assert_equal before + 1, other_count
    assert_nil flash[:error]
  end

  def test_quoted_display_name_of_the_customer_is_one_recipient
    t = transport
    issue = create_ticket(:contact_email => '"Mustermann, Max" <kunde@example.com>, "a,b"@example.com',
                          :cc => 'helpdesk-b@expert.local')

    assert_equal 'kunde@example.com', customer_of(issue)
    assert_includes t.sent.first, '"Mustermann, Max" <kunde@example.com>'
    assert_includes t.sent.first, '"a,b"@example.com'
    assert_nil flash[:error]
  end

  # Only Bcc left besides the hand-over: no mail without a To recipient.
  def test_only_bcc_left_sends_nothing
    RedmineExpertHelpdesk::MailProvider.expects(:outgoing_for).never
    before = other_count
    create_ticket(:contact_email => 'helpdesk-b@expert.local', :bcc => 'kunde@example.com', :move_cc => '1')

    assert_equal before, other_count
    assert flash[:error].present?
  end

  # A target reached by Bcc only must not show up in a public note.
  def test_bcc_only_target_makes_the_note_private
    transport
    issue = create_ticket(:contact_email => 'kunde@example.com', :bcc => 'helpdesk-b@expert.local')

    note = issue.journals.where.not(:notes => [nil, '']).last
    assert_includes note.notes, "##{handed_over.id}"
    assert note.private_notes
    assert_not IssueRelation.where(:issue_from_id => [handed_over.id, issue.id],
                                   :issue_to_id => [handed_over.id, issue.id]).exists?
  end

  # The mail fails after the hand-over: the hand-over stays, and the agent
  # learns both.
  def test_failed_mail_keeps_the_handover_and_says_so
    transport(:fail_with => RedmineExpertHelpdesk::MailProvider::ProviderError.new('SMTP down'))
    before = other_count
    create_ticket(:contact_email => 'kunde@example.com', :cc => 'helpdesk-b@expert.local')

    assert_equal before + 1, other_count
    assert_includes flash[:error], 'SMTP down'
    assert_includes flash[:error], "##{handed_over.id}"
  end

  # Without a hand-over, a failed initial mail used to vanish into the log.
  def test_failed_mail_is_reported
    transport(:fail_with => RedmineExpertHelpdesk::MailProvider::ProviderError.new('SMTP down'))
    create_ticket(:contact_email => 'kunde@example.com')

    assert_includes flash[:error], 'SMTP down'
  end

  # Mail switched off: no hand-over either, the address is just the contact.
  def test_without_mail_nothing_is_handed_over
    RedmineExpertHelpdesk::MailProvider.expects(:outgoing_for).never
    before = other_count
    issue = create_ticket(:send_mail => '0', :contact_email => 'kunde@example.com',
                          :cc => 'helpdesk-b@expert.local')

    assert_equal before, other_count
    assert_equal 'kunde@example.com', customer_of(issue)
  end

  def test_without_the_central_switch_the_address_is_mailed
    Setting.plugin_redmine_expert_helpdesk = @settings_before.merge('handover_enabled' => '0')
    t = transport
    before = other_count
    create_ticket(:contact_email => 'kunde@example.com', :cc => 'helpdesk-b@expert.local')

    assert_equal before, other_count
    assert_includes t.sent.first, 'helpdesk-b@expert.local'
  end

  # --- "assign contact" on an existing ticket ---------------------------------

  def existing_ticket
    Issue.generate!(:project => @project, :subject => 'Bestand', :description => 'Alte Beschreibung').tap do |i|
      HelpdeskTicketInfo.where(:issue_id => i.id).delete_all
    end
  end

  def assign(issue, helpdesk)
    post "/projects/ecookbook/issues/#{issue.id}/helpdesk_init", :params => {
      :helpdesk_init => { :send_mail => '1', :mailbox_id => @mailbox.id.to_s }.merge(helpdesk)
    }
  end

  # Every attachment of the ticket goes over, as it would have gone by mail.
  def test_contact_form_hands_over_the_ticket_attachments
    set_tmp_attachments_directory
    transport
    issue = existing_ticket
    file = Attachment.create!(:container => issue, :author => User.find(2), :filename => 'log.txt',
                              :file => uploaded_test_file('testfile.txt', 'text/plain'))
    assign(issue, :contact_email => 'kunde@example.com', :cc => 'helpdesk-b@expert.local',
                  :mail_body => 'Bitte uebernehmen')

    created = handed_over
    assert_includes created.description, 'Bitte uebernehmen'
    assert created.attachments.any? { |a| a.digest == file.digest }, 'attachment not handed over'
    assert_includes flash[:notice], "##{created.id}"
    assert_nil flash[:error]
  end

  # The initial mail sends the ticket out and a hand-over copies it: neither
  # may start from a ticket the agent cannot see.
  def test_contact_form_needs_a_visible_ticket
    Role.find(1).update!(:issues_visibility => 'own')
    issue = existing_ticket
    issue.update_columns(:author_id => 3, :assigned_to_id => nil)
    before = other_count
    assign(issue, :contact_email => 'helpdesk-b@expert.local')

    assert_response :forbidden
    assert_equal before, other_count
    assert_nil customer_of(issue)
  end

  def test_initial_mail_refuses_an_invisible_ticket
    Role.find(1).update!(:issues_visibility => 'own')
    issue = existing_ticket
    issue.update_columns(:author_id => 3, :assigned_to_id => nil)
    before = other_count

    error = assert_raises(RedmineExpertHelpdesk::InitMailer::Error) do
      RedmineExpertHelpdesk::InitMailer.call(:issue => issue.reload, :contact_email => 'helpdesk-b@expert.local',
                                             :mailbox => @mailbox, :user => User.find(2))
    end
    assert_equal I18n.t(:notice_not_authorized), error.message
    assert_equal before, other_count
    assert_nil customer_of(issue)
  end

  # The source note fails: the committed hand-over is finalized all the same.
  def test_failed_source_note_still_finalizes_the_handover
    transport
    issue = existing_ticket
    Journal.any_instance.stubs(:save!).raises(ActiveRecord::ActiveRecordError, 'note failed')
    RedmineExpertHelpdesk::Handover.expects(:finalize).once

    result = RedmineExpertHelpdesk::InitMailer.call(:issue => issue, :contact_email => 'kunde@example.com',
                                                    :cc => 'helpdesk-b@expert.local', :mailbox => @mailbox,
                                                    :user => User.find(2))
    assert_equal 1, result.handovers.size
    assert result.mailed
  end

  def test_contact_form_without_customer_in_to_reports_it
    RedmineExpertHelpdesk::MailProvider.expects(:outgoing_for).never
    issue = existing_ticket
    before = other_count
    assign(issue, :contact_email => '', :cc => 'kunde@example.com')

    assert_redirected_to "/issues/#{issue.id}"
    assert_equal before, other_count
    assert_nil customer_of(issue)
    assert_equal ERB::Util.h(I18n.t(:error_helpdesk_init_no_to)), flash[:error]
  end

  def test_contact_form_handover_only_says_no_customer_was_assigned
    issue = existing_ticket
    assign(issue, :contact_email => 'helpdesk-b@expert.local')

    assert_includes flash[:notice], "##{handed_over.id}"
    assert_equal ERB::Util.h(I18n.t(:notice_helpdesk_init_handover_only,
                                    :targets => "#{@other.name}: ##{handed_over.id}")), flash[:notice]
  end
end
