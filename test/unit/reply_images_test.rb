require File.expand_path('../../test_helper', __FILE__)

# Aufloesung der Inline-Bilder einer ausgehenden Kundenantwort.
class ReplyImagesTest < ActiveSupport::TestCase
  fixtures :all

  def setup
    @issue = Issue.find(1)
    @issue.attachments.delete_all
    @png = Attachment.create!(
      :container   => @issue,
      :file        => mock_file(:filename => 'image001.png', :content_type => 'image/png'),
      :author      => User.find(1)
    )
    # delete_all above left the association loaded and empty; the controller
    # always works on a freshly loaded issue.
    @issue.attachments.reload
  end

  def mock_file(options)
    Redmine::MimeType # autoload guard
    file = Tempfile.new(['hd', File.extname(options[:filename])])
    file.binmode
    # 1x1 transparent PNG
    file.write(Base64.decode64('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='))
    file.rewind
    def file.original_filename; @original_filename; end
    file.instance_variable_set(:@original_filename, options[:filename])
    def file.content_type; @content_type; end
    file.instance_variable_set(:@content_type, options[:content_type])
    file
  end

  # The actual bug: a quote of the original mail refers to an attachment of the
  # ticket, not to a freshly inserted upload. With that missing from the
  # candidates the image stayed empty for the customer.
  def test_ticket_attachments_are_candidates_without_any_pending_upload
    candidates = RedmineExpertHelpdesk::ReplyImages.candidates(@issue, [])

    assert_includes candidates, @png
  end

  def test_pending_uploads_come_first
    pending = Attachment.new(:filename => 'image001.png')
    candidates = RedmineExpertHelpdesk::ReplyImages.candidates(@issue, [pending])

    assert_equal pending, candidates.first
  end

  def test_non_image_attachments_are_not_candidates
    doc = Attachment.create!(:container => @issue, :author => User.find(1),
                             :file => mock_file(:filename => 'notes.txt',
                                                :content_type => 'text/plain'))
    @issue.attachments.reload
    candidates = RedmineExpertHelpdesk::ReplyImages.candidates(@issue, [])

    assert_not_includes candidates, doc
  end

  # Against the real formatter, so the test does not rest on an assumption
  # about which HTML the wiki markup turns into.
  def test_wiki_image_reference_becomes_a_cid_reference
    note = RedmineExpertHelpdesk::NoteQuoter.description(@issue).content
    html = Redmine::WikiFormatting.formatter.new("![](image001.png)").to_html.to_s
    assert_include 'image001.png', html, "formatter output changed: #{html}"

    candidates    = RedmineExpertHelpdesk::ReplyImages.candidates(@issue, [])
    cid_map, out  = RedmineExpertHelpdesk::ReplyImages.to_cid(html, candidates)

    assert_equal [@png], cid_map.keys
    assert_include "cid:#{cid_map[@png]}", out
    assert_not_include 'src="image001.png"', out
    assert_not_nil note
  end

  def test_to_data_uri_inlines_the_image
    html = '<img src="image001.png" />'
    candidates      = RedmineExpertHelpdesk::ReplyImages.candidates(@issue, [])
    out, embedded   = RedmineExpertHelpdesk::ReplyImages.to_data_uri(html, candidates)

    assert_equal [@png], embedded
    assert_include 'src="data:image/png;base64,', out
  end

  # An already resolved reference must not be replaced a second time.
  def test_already_resolved_sources_are_left_alone
    %w[cid:abc@x data:image/png;base64,AAAA https://example.com/image001.png].each do |src|
      html = %(<img src="#{src}" />)
      _map, out = RedmineExpertHelpdesk::ReplyImages.to_cid(html, [@png])

      assert_equal html, out, "must not rewrite #{src}"
    end
  end

  def test_unreferenced_attachments_are_not_attached
    cid_map, out = RedmineExpertHelpdesk::ReplyImages.to_cid('<p>kein Bild</p>', [@png])

    assert_empty cid_map
    assert_equal '<p>kein Bild</p>', out
  end
end
