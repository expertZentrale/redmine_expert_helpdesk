require File.expand_path('../../test_helper', __FILE__)

# "Include previous message" on the reply form: the latest mail of the
# conversation goes into the mail below the signature, with its images, and the
# sent mail is archived so the next reply can quote it in turn.
class HelpdeskReplyPreviousMessageTest < Redmine::IntegrationTest
  fixtures :projects, :users, :email_addresses, :members, :member_roles, :roles,
           :enabled_modules, :trackers, :projects_trackers, :issue_statuses,
           :enumerations, :issues, :journals

  PNG_BASE64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='.freeze
  CID = 'image001.png@01DD2980.37ED1560'.freeze

  CUSTOMER_MIME = <<~MIME.freeze
    From: Kunde <kunde@example.com>
    To: helpdesk@expert.local
    Date: Wed, 04 Nov 2026 17:55:00 +0100
    Subject: Price list import fails
    MIME-Version: 1.0
    Content-Type: multipart/related; boundary="REL"

    --REL
    Content-Type: text/html; charset=UTF-8

    <html><body><p>The import fails.</p><img src="cid:#{CID}"><script>alert(1)</script></body></html>

    --REL
    Content-Type: image/png; name="image001.png"
    Content-Transfer-Encoding: base64
    Content-ID: <#{CID}>
    Content-Disposition: inline; filename="image001.png"

    #{PNG_BASE64}
    --REL--
  MIME

  # Stands in for the outgoing transport and keeps what it was asked to send.
  class FakeTransport
    attr_reader :sent

    def initialize
      @sent = []
    end

    def send_mail_mime(mime)
      @sent << mime
    end

    def method_missing(*); nil; end

    def respond_to_missing?(*); true; end
  end

  def setup
    @project = Project.find(1)
    @project.enable_module!(:helpdesk)
    Role.find(1).add_permission!(:manage_helpdesk, :send_helpdesk_reply, :view_helpdesk_info)

    @mailbox = HelpdeskMailbox.create!(:project => @project, :mailbox_address => 'helpdesk@expert.local',
                                       :provider => 'imap', :imap_host => 'mail.example.com',
                                       :smtp_host => 'mail.example.com', :reply_transport => 'provider')
    HelpdeskContact.where(:project_id => @project.id).delete_all
    @contact = HelpdeskContact.create!(:project_id => @project.id, :email => 'kunde@example.com', :name => 'Kunde')
    @issue = Issue.find(1)
    HelpdeskMessage.where(:issue_id => @issue.id).delete_all
    HelpdeskTicketInfo.where(:issue_id => @issue.id).delete_all
    HelpdeskTicketInfo.create!(:issue_id => @issue.id, :helpdesk_contact_id => @contact.id,
                               :helpdesk_mailbox_id => @mailbox.id)

    @transport = FakeTransport.new
    RedmineExpertHelpdesk::MailProvider.stubs(:outgoing_for).returns(@transport)

    log_user('jsmith', 'jsmith')
  end

  def reply(params = {})
    post "/issues/#{@issue.id}/helpdesk_reply",
         :params => { :note_content => 'Here is the fix.', :reply_to => 'kunde@example.com' }.merge(params)
    assert_response :success
    JSON.parse(response.body)
  end

  def sent_mail(index = -1)
    Mail.read_from_string(@transport.sent[index])
  end

  def sent_html(index = -1)
    mail = sent_mail(index)
    part = mail.multipart? ? mail.html_part : mail
    part.decoded
  end

  # --- form ---------------------------------------------------------------------

  def test_form_offers_the_checkbox_ticked_when_there_is_a_previous_message
    customer_mail
    get "/issues/#{@issue.id}/edit"

    assert_response :success
    assert_select 'input#hd-include-previous[type=checkbox][checked]', 1
    assert_select 'input#hd-include-previous[name]', 0
  end

  def test_form_has_no_checkbox_without_a_previous_message
    get "/issues/#{@issue.id}/edit"

    assert_response :success
    assert_select 'input#hd-include-previous', 0
  end

  # --- the mail -------------------------------------------------------------------

  def test_previous_message_is_appended_below_the_reply
    customer_mail
    reply(:include_previous => '1')

    html = sent_html
    assert_include 'Here is the fix.', html
    assert_include 'hd-previous-message', html
    assert_include 'The import fails.', html
    assert_include 'Kunde &lt;kunde@example.com&gt;', html
    assert_not_include 'alert(1)', html
    assert html.index('Here is the fix.') < html.index('The import fails.')
  end

  # The cid: image of the customer's mail resolves to the ticket attachment and
  # goes out as an inline part of the reply, like an image the agent pasted.
  def test_previous_message_image_is_sent_inline
    logo = customer_mail(:with_image => true)
    reply(:include_previous => '1')

    mail = sent_mail
    html = sent_html
    cid  = html[/src="cid:([^"]+)"/, 1]
    assert cid, 'image reference missing'
    assert_match(/\Aimg#{logo.id}x/, cid)
    assert mail.all_parts.any? { |p| p.content_id.to_s.include?(cid) }, 'inline part missing'
  end

  def test_unticked_box_leaves_the_mail_as_it_was
    customer_mail
    reply

    html = sent_html
    assert_include 'Here is the fix.', html
    assert_not_include 'hd-previous-message', html
    assert_not_include 'The import fails.', html
  end

  # --- the archived copy -------------------------------------------------------------

  def test_sent_mail_is_archived_without_bcc
    customer_mail
    data = reply(:include_previous => '1', :reply_bcc => 'blind@example.com')

    msg = HelpdeskMessage.find(data['helpdesk_message_id'])
    assert msg.eml_attachment_id
    assert_includes @transport.sent.last, 'Bcc: blind@example.com'
    stored = File.binread(msg.eml_attachment.diskfile)
    assert_not_include 'blind@example.com', stored
    assert_equal 'Sent E-Mail', msg.eml_attachment.description
    assert_equal @issue.id, msg.eml_attachment.container_id
  end

  # The next reply quotes our own answer, which in turn carries the customer's.
  def test_next_reply_quotes_the_archived_reply
    customer_mail
    reply(:include_previous => '1')
    reply(:include_previous => '1', :note_content => 'Second answer.')

    html = sent_html
    assert_include 'Second answer.', html
    assert_include 'helpdesk@expert.local', html[/<p style="margin:0 0 12px 0">.*?<\/p>/m]
    assert_include 'Here is the fix.', html
    assert_include 'The import fails.', html
  end

  def test_archive_failure_does_not_fail_the_reply
    customer_mail
    RedmineExpertHelpdesk::SentMailArchive.stubs(:attach!).raises(RuntimeError, 'disk full').then.returns(nil)
    data = reply(:include_previous => '1')

    assert data['success']
    assert_equal 1, @transport.sent.size
  end

  # A ticket opened with an initial mail: that mail is the first message of the
  # conversation, so it is archived too and the first reply quotes it.
  def test_initial_mail_is_archived_and_quoted_by_the_first_reply
    post '/projects/ecookbook/issues', :params => {
      :issue         => { :tracker_id => 1, :subject => 'Drucker defekt', :description => 'Bitte pruefen',
                          :priority_id => 5 },
      :helpdesk_init => { :send_mail => '1', :mailbox_id => @mailbox.id.to_s, :contact_email => 'kunde@example.com' }
    }
    @issue = Issue.where(:project_id => @project.id).order(:id).last
    initial = HelpdeskMessage.find_by!(:issue_id => @issue.id, :direction => 'out')
    assert initial.eml_attachment_id
    assert_equal 'Sent E-Mail', initial.eml_attachment.description

    reply(:include_previous => '1')

    html = sent_html
    assert_include 'Here is the fix.', html
    assert_include 'Bitte pruefen', html[html.index('hd-previous-message')..]
  end

  # Redmine's global SMTP: the images become data: URIs and Mail builds the
  # MIME; the copy is archived just the same.
  def test_smtp_route_archives_the_sent_mail
    @mailbox.update_columns(:reply_transport => 'smtp')
    RedmineExpertHelpdesk::MailProvider.stubs(:for).returns(stub(:archive_sent => nil))
    ActionMailer::Base.deliveries.clear
    customer_mail
    data = reply(:include_previous => '1', :reply_bcc => 'blind@example.com')

    delivered = ActionMailer::Base.deliveries.last
    assert_include 'The import fails.', (delivered.html_part || delivered).decoded
    msg = HelpdeskMessage.find(data['helpdesk_message_id'])
    stored = File.binread(msg.eml_attachment.diskfile)
    assert_not_include 'blind@example.com', stored
    assert_include 'The import fails.', Mail.read_from_string(stored).then { |m| (m.html_part || m).decoded }
  end

  private

  # The customer's mail as MailProcessor leaves it: a HelpdeskMessage with the
  # archived .eml, and its inline image as a ticket attachment. Returns the image.
  def customer_mail(with_image: false)
    logo = with_image ? attach(Base64.decode64(PNG_BASE64), 'image001.png', 'image/png') : nil
    msg = HelpdeskMessage.create!(:issue => @issue, :helpdesk_contact => @contact, :helpdesk_mailbox => @mailbox,
                                  :direction => 'in', :message_id => 'customer@example.com',
                                  :subject => 'Price list import fails', :sent_at => 1.hour.ago,
                                  :recipient_to => 'helpdesk@expert.local')
    eml = attach(CUSTOMER_MIME.gsub("\n", "\r\n"), 'original_mail.eml', 'application/octet-stream',
                 'Original E-Mail')
    msg.update_column(:eml_attachment_id, eml.id)
    logo
  end

  def attach(bytes, filename, content_type, description = nil)
    io = StringIO.new(bytes.dup.force_encoding('BINARY'))
    io.define_singleton_method(:original_filename) { filename }
    io.define_singleton_method(:content_type)      { content_type }
    Attachment.create!(:container => @issue, :file => io, :author => User.find(2), :description => description)
  end
end
