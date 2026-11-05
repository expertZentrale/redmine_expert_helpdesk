require File.expand_path('../../test_helper', __FILE__)

# The previous message appended below an agent's reply ("Include previous
# message"): which message is chosen, how its body is read from the archived
# .eml, what is sanitized away, and where its images point.
class PreviousMessageTest < ActiveSupport::TestCase
  fixtures :projects, :users, :email_addresses, :roles, :members, :member_roles,
           :issues, :issue_statuses, :trackers, :enumerations, :enabled_modules, :journals

  PM = RedmineExpertHelpdesk::PreviousMessage

  # 1x1 transparent PNG
  PNG_BASE64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='.freeze
  CID = 'image001.png@01DD2980.37ED1560'.freeze

  HTML_MIME = <<~MIME.freeze
    From: =?UTF-8?Q?Adolfo_Ortiz?= <adolfo.ortiz@example.es>
    To: support@example.com
    Cc: jefe@example.es
    Date: Wed, 04 Nov 2026 17:55:00 +0100
    Subject: RE: R: Price list import fails
    MIME-Version: 1.0
    Content-Type: multipart/alternative; boundary="ALT"

    --ALT
    Content-Type: text/plain; charset=UTF-8

    plain alternative

    --ALT
    Content-Type: text/html; charset=ISO-8859-1
    Content-Transfer-Encoding: quoted-printable

    <html><head><style>p { color: red; }</style><title>x</title></head>
    <body lang=3D"es"><p style=3D"font-family:Calibri">Se=F1ores, the import fails.</p>
    <table border=3D"1"><tr><td><font color=3D"blue">cell</font></td></tr></table>
    <script>alert(1)</script>
    <a href=3D"javascript:alert(2)" onclick=3D"alert(3)">bad link</a>
    <a href=3D"https://example.es/doc">good link</a>
    <iframe src=3D"https://evil.example"></iframe>
    </body></html>

    --ALT--
  MIME

  TEXT_MIME = <<~MIME.freeze
    From: kunde@example.com
    To: support@example.com
    Date: Wed, 04 Nov 2026 10:00:00 +0100
    Subject: Only text
    MIME-Version: 1.0
    Content-Type: text/plain; charset=UTF-8

    Line one <b>not bold</b>
    Line two & more
  MIME

  IMAGE_MIME = <<~MIME.freeze
    From: kunde@example.com
    To: support@example.com
    Subject: With a logo
    MIME-Version: 1.0
    Content-Type: multipart/related; boundary="REL"

    --REL
    Content-Type: text/html; charset=UTF-8

    <p>Logo <img src="cid:#{CID}" width="10"> and lost <img src="cid:missing@x"> and <img src="local.png"></p>

    --REL
    Content-Type: image/png; name="image001.png"
    Content-Transfer-Encoding: base64
    Content-ID: <#{CID}>
    Content-Disposition: inline; filename="image001.png"

    #{PNG_BASE64}
    --REL--
  MIME

  def setup
    User.current = User.find(2)
    @issue = Issue.find(1)
    HelpdeskMessage.where(:issue_id => @issue.id).delete_all
    @mailbox = HelpdeskMailbox.create!(:project => @issue.project, :mailbox_address => 'support@example.com',
                                       :provider => 'imap', :imap_host => 'mail.example.com')
    @contact = HelpdeskContact.create!(:project_id => @issue.project_id, :email => 'adolfo.ortiz@example.es',
                                       :name => 'Adolfo Ortiz')
  end

  def teardown
    User.current = nil
  end

  # --- choice of message -------------------------------------------------------

  def test_latest_takes_the_newest_conversation_mail
    incoming(:sent_at => 2.days.ago)
    newer = incoming(:sent_at => 1.hour.ago)

    assert_equal newer, PM.latest(@issue)
  end

  # The autoresponder and the completeness follow-up are logged without a
  # Message-ID: they are not part of the conversation an agent answers.
  def test_latest_skips_automated_outgoing_rows
    customer = incoming(:sent_at => 1.hour.ago)
    hd_message(:direction => 'out', :message_id => nil, :sent_at => 1.minute.ago, :subject => 'Autoresponder')

    assert_equal customer, PM.latest(@issue)
  end

  def test_latest_skips_a_ticket_opened_without_mail
    hd_message(:direction => 'init', :sent_at => Time.current)

    assert_nil PM.latest(@issue)
    assert_nil PM.html_for(@issue)
  end

  def test_latest_takes_our_own_reply_when_it_is_newer
    incoming(:sent_at => 1.hour.ago)
    reply = hd_message(:direction => 'out', :message_id => '<a@example.com>', :sent_at => 1.minute.ago)

    assert_equal reply, PM.latest(@issue)
  end

  # --- incoming HTML ----------------------------------------------------------

  def test_html_mail_gets_an_outlook_style_header
    with_locale('en') do
      html = PM.html_for(@issue.tap { incoming(:mime => HTML_MIME) })

      assert_include '<b>From:</b> Adolfo Ortiz &lt;adolfo.ortiz@example.es&gt;', html
      assert_include '<b>To:</b> support@example.com', html
      assert_include '<b>Cc:</b> jefe@example.es', html
      assert_include '<b>Subject:</b> RE: R: Price list import fails', html
      assert_match %r{<b>Sent:</b> 4 November 2026 \d\d:55}, html
    end
  end

  def test_header_labels_follow_the_language
    with_locale('de') do
      html = PM.html_for(@issue.tap { incoming(:mime => HTML_MIME) })

      assert_include '<b>Von:</b>', html
      assert_include '<b>Betreff:</b>', html
      assert_match %r{<b>Gesendet:</b> 4\. November 2026}, html
    end
  end

  def test_html_body_is_decoded_and_keeps_its_formatting
    html = PM.html_for(@issue.tap { incoming(:mime => HTML_MIME) })

    assert_include 'Señores, the import fails.', html
    assert_include 'style="font-family:Calibri"', html
    assert_include '<table border="1">', html
    assert_include '<font color="blue">cell</font>', html
    assert_include 'href="https://example.es/doc"', html
    assert_not_include 'plain alternative', html
  end

  def test_html_body_is_sanitized
    html = PM.html_for(@issue.tap { incoming(:mime => HTML_MIME) })

    assert_not_include '<script', html
    assert_not_include 'alert(1)', html
    assert_not_include 'javascript:', html
    assert_not_include 'onclick', html
    assert_not_include '<iframe', html
    assert_not_include '<style', html
    assert_not_include 'color: red', html
    assert_not_include '<title', html
    assert_include 'bad link', html
  end

  def test_header_values_are_escaped
    mime = HTML_MIME.sub('Subject: RE: R: Price list import fails', 'Subject: <b>bold</b> & co')
    html = PM.html_for(@issue.tap { incoming(:mime => mime) })

    assert_include '&lt;b&gt;bold&lt;/b&gt; &amp; co', html
  end

  # --- incoming text ----------------------------------------------------------

  def test_text_only_mail_is_escaped_with_line_breaks
    html = PM.html_for(@issue.tap { incoming(:mime => TEXT_MIME) })

    assert_include 'Line one &lt;b&gt;not bold&lt;/b&gt;<br>', html
    assert_include 'Line two &amp; more', html
    assert_not_include '<b>not bold</b>', html
  end

  # --- images ------------------------------------------------------------------

  def test_cid_image_points_at_the_ticket_attachment
    logo = attach_png
    html = PM.html_for(@issue.tap { incoming(:mime => IMAGE_MIME) })

    assert_include %(src="/attachments/download/#{logo.id}/image001.png"), html
    assert_include 'width="10"', html
  end

  def test_unresolvable_images_are_removed
    attach_png
    html = PM.html_for(@issue.tap { incoming(:mime => IMAGE_MIME) })

    assert_not_include 'cid:', html
    assert_not_include 'local.png', html
    assert_equal 1, html.scan('<img').size
    assert_include 'and lost', html
  end

  def test_cid_image_without_its_attachment_is_removed
    html = PM.html_for(@issue.tap { incoming(:mime => IMAGE_MIME) })

    assert_not_include '<img', html
    assert_include 'Logo', html
  end

  # --- legacy fallback ---------------------------------------------------------

  def test_reply_without_eml_falls_back_to_its_journal_note
    journal = Journal.create!(:journalized => @issue, :user => User.find(2), :notes => "Dear customer,\n\n*done*")
    hd_message(:direction => 'out', :message_id => '<a@example.com>', :journal_id => journal.id,
            :recipient_to => 'adolfo.ortiz@example.es', :recipient_cc => 'jefe@example.es',
            :subject => 'Re: [#1] Price list', :sent_at => Time.utc(2026, 11, 4, 9, 0))

    with_locale('en') do
      html = PM.html_for(@issue)

      assert_include '<b>From:</b> support@example.com', html
      assert_include '<b>To:</b> adolfo.ortiz@example.es', html
      assert_include '<b>Cc:</b> jefe@example.es', html
      assert_include '<b>Subject:</b> Re: [#1] Price list', html
      assert_include 'Dear customer,', html
      assert_match %r{<strong>done</strong>|<em>done</em>}, html
    end
  end

  def test_first_incoming_mail_without_eml_falls_back_to_the_description
    @issue.update_columns(:description => 'The original request')
    incoming

    html = PM.html_for(@issue)

    assert_include 'The original request', html
    assert_include 'Adolfo Ortiz &lt;adolfo.ortiz@example.es&gt;', html
  end

  def test_nothing_usable_appends_nothing
    hd_message(:direction => 'out', :message_id => '<a@example.com>', :journal_id => nil)

    assert_nil PM.html_for(@issue)
  end

  # --- sent copies ---------------------------------------------------------------

  def test_sent_copy_is_stored_without_bcc
    msg  = hd_message(:direction => 'out', :message_id => '<a@example.com>')
    mime = "From: support@example.com\r\nTo: kunde@example.com\r\nBcc: secret@example.com,\r\n" \
           " other@example.com\r\nSubject: Re\r\nContent-Type: text/html; charset=UTF-8\r\n\r\n<p>Hi</p>"

    att = RedmineExpertHelpdesk::SentMailArchive.attach!(msg, mime, User.find(2))

    assert att
    assert_equal att.id, msg.reload.eml_attachment_id
    assert_equal 'Sent E-Mail', att.description
    assert_match(/\Asent_mail_\d{8}_\d{6}\.eml\z/, att.filename)
    stored = File.binread(att.diskfile)
    assert_not_include 'secret@example.com', stored
    assert_not_include 'other@example.com', stored
    assert_include "Subject: Re\r\n", stored
    assert_include "\r\n\r\n<p>Hi</p>", stored
  end

  def test_bcc_as_last_header_keeps_the_header_block_intact
    stripped = RedmineExpertHelpdesk::SentMailArchive.strip_bcc("To: a@x\nBcc: b@x\n\nbody\nBcc: stays\n")

    assert_equal "To: a@x\n\nbody\nBcc: stays\n", stripped
  end

  def test_failed_archive_is_swallowed
    msg = hd_message(:direction => 'out', :message_id => '<a@example.com>')
    Attachment.any_instance.stubs(:save!).raises(ActiveRecord::RecordInvalid)

    assert_nil RedmineExpertHelpdesk::SentMailArchive.attach!(msg, "To: a@x\n\nbody", User.find(2))
    assert_nil msg.reload.eml_attachment_id
  end

  def test_archived_copies_are_not_customer_evidence
    assert RedmineExpertHelpdesk::SentMailArchive.archived_eml?(Attachment.new(:description => 'Sent E-Mail'))
    assert RedmineExpertHelpdesk::SentMailArchive.archived_eml?(Attachment.new(:description => 'Original E-Mail'))
    assert_not RedmineExpertHelpdesk::SentMailArchive.archived_eml?(Attachment.new(:description => 'Screenshot'))
  end

  private

  def hd_message(attrs = {})
    HelpdeskMessage.create!({ :issue => @issue, :helpdesk_contact => @contact, :helpdesk_mailbox => @mailbox,
                              :sent_at => Time.current }.merge(attrs))
  end

  def incoming(mime: nil, **attrs)
    msg = hd_message({ :direction => 'in', :message_id => "m#{SecureRandom.hex(4)}@example.es",
                    :recipient_to => 'support@example.com' }.merge(attrs))
    if mime
      att = attach(mime.gsub("\n", "\r\n"), 'original_mail.eml', 'Original E-Mail')
      msg.update_column(:eml_attachment_id, att.id)
    end
    msg
  end

  def attach(bytes, filename, description = nil, content_type = 'application/octet-stream')
    io = StringIO.new(bytes.dup.force_encoding('BINARY'))
    io.define_singleton_method(:original_filename) { filename }
    io.define_singleton_method(:content_type)      { content_type }
    att = Attachment.create!(:container => @issue, :file => io, :author => User.find(2),
                             :description => description)
    @issue.reload
    att
  end

  def attach_png
    attach(Base64.decode64(PNG_BASE64), 'image001.png', nil, 'image/png')
  end

  def with_locale(code, &block)
    I18n.with_locale(code, &block)
  end
end
