require File.expand_path('../../test_helper', __FILE__)

# Inline images of incoming mails: the "[cid:...]" markers MailHandler leaves in
# the text are replaced by image syntax pointing at the saved attachments.
class InlineImagesTest < ActiveSupport::TestCase
  fixtures :all

  II = RedmineExpertHelpdesk::InlineImages

  # 1x1 transparent PNG
  PNG_BASE64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='.freeze

  CID = 'image001.png@01DD2980.37ED1560'.freeze

  TEXT_MIME = <<~MIME.freeze
    From: dennis@example.de
    To: helpdesk@example.com
    Subject: Signature
    MIME-Version: 1.0
    Content-Type: multipart/related; boundary="REL"

    --REL
    Content-Type: text/plain; charset=UTF-8

    Dennis Buehring
    [cid:#{CID}]

    --REL
    Content-Type: image/png; name="image001.png"
    Content-Transfer-Encoding: base64
    Content-ID: <#{CID}>
    Content-Disposition: inline; filename="image001.png"

    #{PNG_BASE64}
    --REL--
  MIME

  HTML_ONLY_MIME = <<~MIME.freeze
    From: dennis@example.de
    To: helpdesk@example.com
    Subject: Signature
    MIME-Version: 1.0
    Content-Type: multipart/related; boundary="REL"

    --REL
    Content-Type: text/html; charset=UTF-8

    <p>Hallo<img src="cid:#{CID}" width="10" alt="Logo"></p>

    --REL
    Content-Type: image/png; name="image001.png"
    Content-Transfer-Encoding: base64
    Content-ID: <#{CID}>
    Content-Disposition: inline; filename="image001.png"

    #{PNG_BASE64}
    --REL--
  MIME

  Att = Struct.new(:id, :filename)

  def setup
    logo = Att.new(7, 'image001.png')
    @index = { CID.downcase => logo, 'image001.png' => logo }
  end

  # -----------------------------------------------------------------------
  # Marker forms
  # -----------------------------------------------------------------------

  def test_outlook_marker_becomes_image
    with_settings :text_formatting => 'markdown' do
      assert_equal "Gruss\n![](image001.png)\n",
                   II.replace_markers("Gruss\n[cid:#{CID}]\n", @index)
    end
  end

  def test_gmail_marker_becomes_image
    with_settings :text_formatting => 'markdown' do
      assert_equal '![](image001.png)', II.replace_markers('[image: image001.png]', @index)
    end
  end

  def test_textile_formatting_uses_textile_syntax
    with_settings :text_formatting => 'textile' do
      assert_equal '!image001.png!', II.replace_markers("[cid:#{CID}]", @index)
    end
  end

  # Raw HTML that survived into the body keeps its tag - only the reference is
  # exchanged, so size and alt stay intact.
  def test_img_tag_keeps_attributes
    assert_equal %(<img src="image001.png" width="10">),
                 II.replace_markers(%(<img src="cid:#{CID}" width="10">), @index)
  end

  def test_unknown_reference_is_left_alone
    text = '[cid:image999.png@01DD.99]'
    assert_equal text, II.replace_markers(text, @index)
  end

  # Without a resolvable attachment list the markup has to name the download path.
  def test_fallback_uses_download_path
    with_settings :text_formatting => 'markdown' do
      assert_equal '![](/attachments/download/7/image001.png)',
                   II.replace_markers("[cid:#{CID}]", @index, false)
    end
  end

  def test_special_characters_in_filename_are_encoded
    index = { 'bild 1.png' => Att.new(8, 'Bild (1).png') }
    with_settings :text_formatting => 'markdown' do
      assert_equal '![](Bild%20%281%29.png)', II.replace_markers('[image: bild 1.png]', index)
    end
  end

  # Redmine's own sanitizing keeps "%" out of stored file names; the encoding must
  # not depend on that to stay unambiguous.
  def test_percent_in_filename_is_encoded
    assert_equal 'a%2520b.png', II.escape_target('a%20b.png')
  end

  # -----------------------------------------------------------------------
  # CID map
  # -----------------------------------------------------------------------

  def test_cid_index_maps_content_id_and_filename
    attachment = Att.new(7, 'image001.png')
    index = II.cid_index(Mail.read_from_string(TEXT_MIME), [attachment])

    assert_equal attachment, index[CID.downcase]
    assert_equal attachment, index['image001.png']
  end

  def test_cid_index_skips_parts_without_a_stored_attachment
    assert_empty II.cid_index(Mail.read_from_string(TEXT_MIME), [])
  end

  def test_cid_index_ignores_non_image_attachments
    mime = TEXT_MIME.sub('image/png; name="image001.png"', 'application/pdf; name="invoice.pdf"')
                    .sub('filename="image001.png"', 'filename="invoice.pdf"')
    assert_empty II.cid_index(Mail.read_from_string(mime), [Att.new(7, 'invoice.pdf')])
  end

  # -----------------------------------------------------------------------
  # MIME preprocessing (HTML bodies)
  # -----------------------------------------------------------------------

  # Redmine's HTML-to-text parser drops <img> without a trace, so the reference is
  # turned into the marker a text body would carry.
  def test_prepare_mime_marks_images_of_html_only_mails
    prepared = II.prepare_mime(HTML_ONLY_MIME)
    html = Mail.read_from_string(prepared).all_parts.detect { |p| p.mime_type == 'text/html' }

    assert_includes html.body.decoded, "[cid:#{CID}]"
    assert_not_includes html.body.decoded, '<img'
  end

  # A mail with a text alternative already carries the markers - nothing to do.
  def test_prepare_mime_leaves_mails_with_a_text_part_untouched
    assert_equal TEXT_MIME, II.prepare_mime(TEXT_MIME)
  end

  # No Content-ID header means no part the reference could resolve to, so the mail
  # is passed on without being parsed at all.
  def test_prepare_mime_skips_mails_without_a_content_id
    mime = HTML_ONLY_MIME.gsub(/^Content-ID:.*\n/i, '')

    assert_includes mime, 'src="cid:'
    assert_equal mime, II.prepare_mime(mime)
  end

  def test_prepare_mime_survives_broken_mime
    assert_equal 'not a mail at all', II.prepare_mime('not a mail at all')
  end

  # -----------------------------------------------------------------------
  # rewrite! on the objects MailHandler creates
  # -----------------------------------------------------------------------

  def test_rewrite_replaces_marker_in_issue_description
    issue = issue_with_description("Hallo\n[cid:#{CID}]")
    attach_png(issue)

    with_settings :text_formatting => 'markdown' do
      assert II.rewrite!(issue, TEXT_MIME)
    end
    assert_equal "Hallo\n![](image001.png)", issue.reload.description
  end

  def test_rewrite_replaces_marker_in_journal_note
    issue = issue_with_description('Ticket')
    journal = Journal.create!(:journalized => issue, :user => User.find(2),
                              :notes => "Antwort\n[cid:#{CID}]")
    attachment = attach_png(issue)
    JournalDetail.create!(:journal => journal, :property => 'attachment',
                          :prop_key => attachment.id, :value => attachment.filename)

    with_settings :text_formatting => 'markdown' do
      assert II.rewrite!(journal, TEXT_MIME)
    end
    assert_equal "Antwort\n![](image001.png)", journal.reload.notes
  end

  # No attachment detail on the journal means Redmine cannot resolve a bare file
  # name in that note, so the markup names the download path instead.
  def test_rewrite_falls_back_to_download_path_without_journal_attachments
    issue = issue_with_description('Ticket')
    journal = Journal.create!(:journalized => issue, :user => User.find(2),
                              :notes => "[cid:#{CID}]")
    attachment = attach_png(issue)

    with_settings :text_formatting => 'markdown' do
      assert II.rewrite!(journal, TEXT_MIME)
    end
    assert_equal "![](/attachments/download/#{attachment.id}/image001.png)", journal.reload.notes
  end

  # MailHandler saves the issue again while storing the mail's attachments, so the
  # instance it hands back carries an outdated lock_version. Writing through
  # update_columns would match no row and report nothing.
  def test_rewrite_writes_through_a_stale_lock_version
    issue = issue_with_description("[cid:#{CID}]")
    attach_png(issue)
    Issue.where(:id => issue.id).update_all('lock_version = lock_version + 1')

    with_settings :text_formatting => 'markdown' do
      assert II.rewrite!(issue, TEXT_MIME)
    end
    assert_equal '![](image001.png)', issue.reload.description
  end

  def test_rewrite_is_a_noop_without_markers
    issue = issue_with_description('Kein Bild hier')
    attach_png(issue)

    assert_not II.rewrite!(issue, TEXT_MIME)
    assert_equal 'Kein Bild hier', issue.reload.description
  end

  def test_rewrite_can_be_switched_off
    issue = issue_with_description("[cid:#{CID}]")
    attach_png(issue)

    with_settings :plugin_redmine_expert_helpdesk => { 'inline_images_enabled' => '0' } do
      assert_not II.rewrite!(issue, TEXT_MIME)
    end
    assert_equal "[cid:#{CID}]", issue.reload.description
  end

  private

  # update_columns: the description is the mail body here, no journal wanted.
  def issue_with_description(text)
    issue = Issue.find(1)
    issue.update_columns(:description => text)
    issue
  end

  # Attachment straight from memory - the same StringIO trick MailProcessor uses
  # for the .eml, so the test needs no fixture file.
  def attach_png(container, filename = 'image001.png')
    io = StringIO.new(Base64.decode64(PNG_BASE64))
    io.define_singleton_method(:original_filename) { filename }
    io.define_singleton_method(:content_type)      { 'image/png' }

    attachment = Attachment.create!(:container => container, :file => io, :author => User.find(2))
    container.reload
    attachment
  end
end
