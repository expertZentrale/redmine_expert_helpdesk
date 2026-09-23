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
      assert_equal "Gruss\n![](/attachments/download/7/image001.png)\n",
                   II.replace_markers("Gruss\n[cid:#{CID}]\n", @index)
    end
  end

  def test_gmail_marker_becomes_image
    with_settings :text_formatting => 'markdown' do
      assert_equal '![](/attachments/download/7/image001.png)',
                   II.replace_markers('[image: image001.png]', @index)
    end
  end

  def test_textile_formatting_uses_textile_syntax
    with_settings :text_formatting => 'textile' do
      assert_equal '!/attachments/download/7/image001.png!',
                   II.replace_markers("[cid:#{CID}]", @index)
    end
  end

  # Raw HTML that survived into the body keeps its tag - only the reference is
  # exchanged, so size and alt stay intact.
  def test_img_tag_keeps_attributes
    assert_equal %(<img src="/attachments/download/7/image001.png" width="10">),
                 II.replace_markers(%(<img src="cid:#{CID}" width="10">), @index)
  end

  def test_unknown_reference_is_left_alone
    text = '[cid:image999.png@01DD.99]'
    assert_equal text, II.replace_markers(text, @index)
  end

  # A bare file name is a lookup, not a reference: Redmine resolves it against every
  # attachment of the rendered object and takes the newest match. The markup names
  # the download path in every case so that it cannot be taken over by a later file
  # of the same name.
  def test_markup_always_names_the_download_path
    with_settings :text_formatting => 'markdown' do
      assert_equal '![](/attachments/download/7/image001.png)',
                   II.replace_markers("[cid:#{CID}]", @index)
    end
  end

  def test_special_characters_in_filename_are_encoded
    index = { 'bild 1.png' => Att.new(8, 'Bild (1).png') }
    with_settings :text_formatting => 'markdown' do
      assert_equal '![](/attachments/download/8/Bild%20%281%29.png)',
                   II.replace_markers('[image: bild 1.png]', index)
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
    assert_equal "Hallo\n![](/attachments/download/#{issue.attachments.first.id}/image001.png)",
                 issue.reload.description
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
    assert_equal "Antwort\n![](/attachments/download/#{attachment.id}/image001.png)",
                 journal.reload.notes
  end

  # A journal without attachment details of its own falls back to the issue's
  # attachments to find the file; the markup is the download path either way.
  def test_rewrite_resolves_through_the_issue_without_journal_attachments
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
    assert_equal "![](/attachments/download/#{issue.attachments.first.id}/image001.png)",
                 issue.reload.description
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

  # -----------------------------------------------------------------------
  # Several embedded images under one file name (Outlook)
  # -----------------------------------------------------------------------
  #
  # Reproduces the shape of a real mail (ticket #927242): Outlook names every
  # embedded image "image.png", so a signature with a logo, a phone icon, a mail
  # icon and four social icons arrives as distinct Content-IDs sharing one name.
  # Matching parts to attachments by name alone gave every marker the same file and
  # the ticket showed one picture nine times over.

  def test_each_content_id_maps_to_its_own_attachment
    issue = issue_with_description('Ticket')
    attachments = SAME_NAME_SIZES.map { |bytes| attach_sized(issue, 'image.png', bytes) }

    index = II.cid_index(Mail.read_from_string(same_name_mime), II.attachment_scope(issue))

    mapped = SAME_NAME_CIDS.map { |cid| index[cid] }
    assert_equal SAME_NAME_CIDS.size, mapped.compact.map(&:id).uniq.size,
                 'every Content-ID must resolve to a different attachment'
    # The part's byte count decides, so each cid lands on the file of its own size.
    SAME_NAME_CIDS.each_with_index do |cid, i|
      assert_equal SAME_NAME_SIZES[i], index[cid].filesize,
                   "cid #{cid} resolved to the wrong file"
    end
    assert_equal attachments.map(&:id).sort, mapped.map(&:id).sort
  end

  def test_same_named_images_render_as_different_pictures
    issue = issue_with_description(SAME_NAME_CIDS.map { |c| "[cid:#{c}]" }.join("\n"))
    SAME_NAME_SIZES.each { |bytes| attach_sized(issue, 'image.png', bytes) }

    with_settings :text_formatting => 'markdown' do
      assert II.rewrite!(issue, same_name_mime)
    end

    links = issue.reload.description.scan(%r{!\[\]\((/attachments/download/\d+/image\.png)\)})
    assert_equal SAME_NAME_CIDS.size, links.size
    assert_equal SAME_NAME_CIDS.size, links.uniq.size,
                 'the markers must point at different files, not all at the newest'
  end

  # MailHandler may store fewer images than the mail carries - one excluded by size
  # or by "Excluded attachment file names". The part left without a file of its own
  # must keep its marker rather than borrow a picture that belongs to another cid.
  def test_a_part_without_its_own_attachment_is_left_unresolved
    issue = issue_with_description('Ticket')
    # Three parts in the mail, two files stored.
    attach_sized(issue, 'image.png', SAME_NAME_SIZES[0])
    attach_sized(issue, 'image.png', SAME_NAME_SIZES[1])

    index = II.cid_index(Mail.read_from_string(same_name_mime), II.attachment_scope(issue))

    resolved = SAME_NAME_CIDS.map { |cid| index[cid] }.compact
    assert_equal 2, resolved.size, 'only the parts with a stored file may resolve'
    assert_equal 2, resolved.map(&:id).uniq.size, 'no attachment may be handed out twice'
  end

  private

  # Distinct byte counts, as in the reported mail (logo, icons, screenshot).
  SAME_NAME_SIZES = [8301, 831, 844, 767, 1297, 77237].freeze
  SAME_NAME_CIDS  = %w[
    f4730a4f-c265-4d57-a1a6-77187e709eb6
    275db269-5de0-412f-a18f-72afce1d679f
    047334f5-150e-4920-95c5-8ca727629df6
    2899d7f4-0b4f-4e50-b1e0-c2ffe1a8433d
    2aaa8da9-fa6d-48ba-ba61-29fabf18ecae
    06bbae6e-06b1-4c79-90c2-02c00d9f63ea
  ].freeze

  # One multipart/related mail, every part called image.png, each a different size.
  def same_name_mime
    parts = SAME_NAME_CIDS.each_with_index.map do |cid, i|
      <<~PART
        --REL
        Content-Type: image/png; name="image.png"
        Content-Transfer-Encoding: base64
        Content-ID: <#{cid}>
        Content-Disposition: inline; filename="image.png"

        #{Base64.strict_encode64(png_of(SAME_NAME_SIZES[i]))}
      PART
    end

    <<~MIME
      From: michael@example.de
      To: helpdesk@example.com
      Subject: Programme auf Interimsrechner
      MIME-Version: 1.0
      Content-Type: multipart/related; boundary="REL"

      --REL
      Content-Type: text/plain; charset=UTF-8

      #{SAME_NAME_CIDS.map { |c| "[cid:#{c}]" }.join("\n")}

      #{parts.join}--REL--
    MIME
  end

  # A PNG header followed by filler, so the bytes are a valid image of a given size
  # and every size is a different file.
  def png_of(bytes)
    head = Base64.decode64(PNG_BASE64)
    head + ('x' * [bytes - head.bytesize, 0].max)
  end

  def attach_sized(container, filename, bytes)
    io = StringIO.new(png_of(bytes))
    io.define_singleton_method(:original_filename) { filename }
    io.define_singleton_method(:content_type)      { 'image/png' }

    attachment = Attachment.create!(:container => container, :file => io, :author => User.find(2))
    container.reload
    attachment
  end

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
