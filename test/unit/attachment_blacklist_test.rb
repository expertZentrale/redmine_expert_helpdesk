require File.expand_path('../../test_helper', __FILE__)

# Per-project blacklist of attachment contents: signature logos, icons and
# tracking pixels an agent has blocked are dropped during ingestion and purged
# from the tickets they already sit on.
class AttachmentBlacklistTest < ActiveSupport::TestCase
  fixtures :all

  AB = RedmineExpertHelpdesk::AttachmentBlacklist

  # Two different 1x1 PNGs - transparent and red. The blacklist matches on content,
  # so a test that wants two files it can tell apart needs two different files:
  # the same bytes under two names are, correctly, one blocked file.
  PNG_BASE64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=='.freeze
  OTHER_PNG_BASE64 = 'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC'.freeze

  def setup
    @issue = Issue.find(1)
    @project = @issue.project
    User.current = User.find(2)
    @settings_snapshot = Setting.plugin_redmine_expert_helpdesk.dup
  end

  def teardown
    User.current = nil
    Setting.plugin_redmine_expert_helpdesk = @settings_snapshot if @settings_snapshot
  end

  # -----------------------------------------------------------------------
  # Digest
  # -----------------------------------------------------------------------

  def test_digest_is_sha256_of_the_file_content
    attachment = attach_png(@issue)
    assert_equal Digest::SHA256.file(attachment.diskfile).hexdigest,
                 HelpdeskAttachmentBlacklist.digest_for(attachment)
  end

  def test_digest_is_nil_when_the_file_is_gone
    attachment = attach_png(@issue)
    File.delete(attachment.diskfile)
    assert_nil HelpdeskAttachmentBlacklist.digest_for(attachment)
  end

  def test_same_content_under_different_names_has_the_same_digest
    one = attach_png(@issue, 'image001.png')
    two = attach_png(@issue, 'logo.png')
    assert_equal HelpdeskAttachmentBlacklist.digest_for(one),
                 HelpdeskAttachmentBlacklist.digest_for(two)
  end

  # -----------------------------------------------------------------------
  # Ingestion filter
  # -----------------------------------------------------------------------

  def test_filter_drops_a_blacklisted_attachment
    attachment = attach_png(@issue)
    blacklist(attachment)

    assert_equal 1, AB.filter!(@issue, @issue)
    assert_nil Attachment.find_by(:id => attachment.id)
  end

  def test_filter_keeps_an_attachment_that_is_not_blacklisted
    attachment = attach_png(@issue)

    assert_equal 0, AB.filter!(@issue, @issue)
    assert Attachment.exists?(attachment.id)
  end

  def test_filter_counts_the_hit_on_the_entry
    attachment = attach_png(@issue)
    entry = blacklist(attachment)

    AB.filter!(@issue, @issue)
    entry.reload
    assert_equal 1, entry.hit_count
    assert_not_nil entry.last_hit_at
  end

  def test_filter_is_scoped_to_the_project
    attachment = attach_png(@issue)
    other = Project.where.not(:id => @project.id).first
    HelpdeskAttachmentBlacklist.create!(
      :project_id => other.id,
      :digest => HelpdeskAttachmentBlacklist.digest_for(attachment),
      :filesize => attachment.filesize,
      :created_on => Time.current
    )

    assert_equal 0, AB.filter!(@issue, @issue)
    assert Attachment.exists?(attachment.id)
  end

  def test_filter_drops_a_reply_attachment_only_from_its_own_journal
    on_issue = attach_png(@issue, 'logo.png')
    journal = reply_with_attachment('logo.png')
    on_journal = journal.attachments.first
    blacklist(on_journal)

    assert_equal 1, AB.filter!(journal, @issue)
    assert_nil Attachment.find_by(:id => on_journal.id)
    # Same bytes, but the issue's copy came with an earlier mail: this ingestion
    # run has no business deleting it. The retroactive purge is what clears those.
    assert Attachment.exists?(on_issue.id)
  end

  def test_filter_survives_an_unreadable_file
    attachment = attach_png(@issue)
    blacklist(attachment)
    File.delete(attachment.diskfile)

    assert_equal 0, AB.filter!(@issue, @issue)
  end

  # -----------------------------------------------------------------------
  # Markup cleanup
  # -----------------------------------------------------------------------

  def test_filter_strips_the_textile_markup_of_the_dropped_file
    with_settings :text_formatting => 'textile' do
      attachment = attach_png(@issue)
      set_description("Mit freundlichen Gruessen\n\n!image001.png!\n")
      blacklist(attachment)

      AB.filter!(@issue, @issue)
      assert_equal 'Mit freundlichen Gruessen', @issue.reload.description
    end
  end

  def test_filter_strips_the_markdown_markup_of_the_dropped_file
    with_settings :text_formatting => 'markdown' do
      attachment = attach_png(@issue)
      set_description("Gruss\n\n![](image001.png)\n")
      blacklist(attachment)

      AB.filter!(@issue, @issue)
      assert_equal 'Gruss', @issue.reload.description
    end
  end

  def test_filter_strips_the_download_path_form
    attachment = attach_png(@issue)
    set_description("Gruss\n\n![](/attachments/download/#{attachment.id}/image001.png)\n")
    blacklist(attachment)

    AB.filter!(@issue, @issue)
    assert_equal 'Gruss', @issue.reload.description
  end

  def test_filter_strips_a_surviving_img_tag
    attachment = attach_png(@issue)
    set_description(%(Gruss<img src="image001.png" width="100">))
    blacklist(attachment)

    AB.filter!(@issue, @issue)
    assert_equal 'Gruss', @issue.reload.description
  end

  def test_stripping_leaves_other_images_alone
    with_settings :text_formatting => 'textile' do
      logo = attach_png(@issue, 'image001.png')
      attach_other_png(@issue, 'screenshot.png')
      set_description("!image001.png!\n\n!screenshot.png!")
      blacklist(logo)

      AB.filter!(@issue, @issue)
      assert_equal '!screenshot.png!', @issue.reload.description
    end
  end

  def test_stripping_writes_no_journal
    attachment = attach_png(@issue)
    set_description("Gruss\n\n!image001.png!")
    blacklist(attachment)

    assert_no_difference 'Journal.count' do
      AB.filter!(@issue, @issue)
    end
  end

  # -----------------------------------------------------------------------
  # Retroactive purge
  # -----------------------------------------------------------------------

  def test_purge_removes_every_copy_in_the_project
    on_issue = attach_png(@issue)
    on_reply = reply_with_attachment('logo.png').attachments.first
    other_issue = Issue.where(:project_id => @project.id).where.not(:id => @issue.id).first
    on_other = attach_png(other_issue)
    entry = blacklist(on_issue)

    assert_equal 3, AB.purge!(@project, entry)
    [on_issue, on_reply, on_other].each do |a|
      assert_nil Attachment.find_by(:id => a.id), "#{a.filename} survived the purge"
    end
  end

  # Redmine files a reply's attachments under the issue, but rows with
  # container_type 'Journal' exist in the wild - HelpdeskAiSummaryJob looks at both,
  # and so does the purge.
  def test_purge_covers_attachments_filed_under_a_journal
    journal = Journal.create!(:journalized => @issue, :user => User.find(2), :notes => 'Reply')
    on_journal = attach_png(journal)
    entry = blacklist(on_journal)

    assert_equal 1, AB.purge!(@project, entry)
    assert_nil Attachment.find_by(:id => on_journal.id)
  end

  def test_purge_leaves_other_projects_alone
    attachment = attach_png(@issue)
    foreign_issue = Issue.where.not(:project_id => @project.id).first
    foreign = attach_png(foreign_issue)
    entry = blacklist(attachment)

    AB.purge!(@project, entry)
    assert Attachment.exists?(foreign.id)
  end

  # A reply's attachments are stored on the issue but journalized onto the note that
  # brought them, and that note - not the description - holds their markup. Cleaning
  # the container alone would delete the file and leave the note showing a broken
  # image, which is exactly what this feature exists to prevent.
  def test_purge_cleans_the_note_a_reply_attachment_belongs_to
    with_settings :text_formatting => 'textile' do
      journal = reply_with_attachment('image001.png')
      attachment = journal.attachments.first
      Journal.where(:id => journal.id).update_all(:notes => "Gruss\n\n!image001.png!")
      entry = blacklist(attachment)

      AB.purge!(@project, entry)
      assert_equal 'Gruss', journal.reload.notes
    end
  end

  # "image001.png" is whatever the sender's Outlook numbered first, so the bare name
  # in the markup does not name a specific file - Redmine resolves it against the
  # whole container. Stripping it when a sibling shares the name would blank the
  # markup of a screenshot that is merely called image001.png too.
  def test_stripping_spares_the_markup_of_a_same_named_attachment
    with_settings :text_formatting => 'textile' do
      logo = attach_png(@issue, 'image001.png')
      screenshot = attach_other_png(@issue, 'image001.png')
      set_description("!image001.png!")
      entry = blacklist(logo)

      AB.purge!(@project, entry)
      assert Attachment.exists?(screenshot.id), 'the screenshot must survive'
      assert_equal '!image001.png!', @issue.reload.description
    end
  end

  # With no sibling of that name the bare form is unambiguous and must still go.
  def test_stripping_removes_the_bare_name_when_it_is_unambiguous
    with_settings :text_formatting => 'textile' do
      logo = attach_png(@issue, 'image001.png')
      set_description("!image001.png!")
      entry = blacklist(logo)

      AB.purge!(@project, entry)
      assert_equal '', @issue.reload.description
    end
  end

  def test_count_copies_predicts_the_purge
    attach_png(@issue)
    entry = blacklist(attach_png(@issue, 'logo.png'))

    predicted = AB.count_copies(@project, entry)
    assert_equal predicted, AB.purge!(@project, entry)
  end

  def test_purge_ignores_a_file_of_a_different_size
    attachment = attach_png(@issue)
    entry = blacklist(attachment)
    other = attach_text(@issue, 'notes.txt', 'a much longer body than a 1x1 png')

    AB.purge!(@project, entry)
    assert Attachment.exists?(other.id)
  end

  # -----------------------------------------------------------------------
  # Eligibility: which files may be blacklisted at all
  # -----------------------------------------------------------------------

  def test_a_small_image_is_blacklistable
    assert AB.eligible?(attach_png(@issue), @project)
  end

  def test_a_pdf_is_not_blacklistable
    pdf = attach(@issue, 'handbuch.pdf', 'application/pdf', '%PDF-1.4 ...')
    assert_not AB.eligible?(pdf, @project)
  end

  # The archived original mail hangs on every helpdesk ticket - blocking one would
  # be both useless (each is unique) and destructive.
  def test_an_eml_is_not_blacklistable
    eml = attach(@issue, 'Original.eml', 'message/rfc822', 'From: a@b.c')
    assert_not AB.eligible?(eml, @project)
  end

  def test_an_image_above_the_size_limit_is_not_blacklistable
    big = attach(@issue, 'screenshot.png', 'image/png', 'x' * (120 * 1024))
    assert_not AB.eligible?(big, @project)

    settings(:blacklist_max_kb => '200')
    assert AB.eligible?(big, @project)
  end

  def test_the_size_limit_can_be_switched_off
    big = attach(@issue, 'screenshot.png', 'image/png', 'x' * (120 * 1024))
    settings(:blacklist_max_kb => '0')
    assert AB.eligible?(big, @project)
  end

  def test_a_mime_rule_matches_when_the_extension_does_not
    settings(:blacklist_types => 'image/*')
    odd = attach(@issue, 'signature', 'image/png', Base64.decode64(PNG_BASE64))
    assert AB.eligible?(odd, @project)
  end

  def test_an_exact_mime_rule_matches_only_that_type
    settings(:blacklist_types => 'image/gif')
    assert_not AB.eligible?(attach_png(@issue), @project)
  end

  def test_a_star_allows_every_type
    settings(:blacklist_types => '*')
    pdf = attach(@issue, 'handbuch.pdf', 'application/pdf', '%PDF-1.4')
    assert AB.eligible?(pdf, @project)
  end

  def test_the_project_overrides_the_central_types
    settings(:blacklist_types => 'gif')
    png = attach_png(@issue)
    assert_not AB.eligible?(png, @project)

    project_setting.update!(:blacklist_types => 'png')
    assert AB.eligible?(png, @project)
  end

  def test_the_project_overrides_the_central_size_limit
    big = attach(@issue, 'logo.png', 'image/png', 'x' * (120 * 1024))
    project_setting.update!(:blacklist_max_kb => 200)
    assert AB.eligible?(big, @project)
  end

  # The guard has to hold on an install whose settings form was never saved after
  # the upgrade: the key is simply absent there, and a missing allow list must not
  # read as "everything is allowed".
  def test_a_missing_central_setting_falls_back_to_the_defaults
    Setting.stubs(:plugin_redmine_expert_helpdesk).returns({})

    assert AB.eligible?(attach_png(@issue), @project)
    assert_not AB.eligible?(attach(@issue, 'x.pdf', 'application/pdf', 'x'), @project)
  end

  def test_eligible_ids_covers_the_issue_and_its_journals
    png = attach_png(@issue)
    pdf = attach(@issue, 'handbuch.pdf', 'application/pdf', '%PDF')
    on_reply = reply_with_attachment('logo.png').attachments.first

    ids = AB.eligible_ids(@issue.reload)
    assert_includes ids, png.id
    assert_includes ids, on_reply.id
    assert_not_includes ids, pdf.id
  end

  # -----------------------------------------------------------------------
  # Model
  # -----------------------------------------------------------------------

  def test_digest_must_be_a_sha256
    entry = HelpdeskAttachmentBlacklist.new(:project_id => @project.id, :digest => 'nope',
                                            :created_on => Time.current)
    assert_not entry.valid?
    assert entry.errors[:digest].present?
  end

  def test_digest_is_unique_per_project
    attachment = attach_png(@issue)
    blacklist(attachment)
    duplicate = HelpdeskAttachmentBlacklist.new(
      :project_id => @project.id,
      :digest => HelpdeskAttachmentBlacklist.digest_for(attachment),
      :created_on => Time.current
    )
    assert_not duplicate.valid?
  end

  private

  # Overwrites individual central plugin settings for one test; setup/teardown of
  # the suite restore the rest.
  def settings(values)
    current = Setting.plugin_redmine_expert_helpdesk.dup
    Setting.plugin_redmine_expert_helpdesk = current.merge(values.stringify_keys)
  end

  def project_setting
    HelpdeskProjectSetting.find_or_create_by!(:project_id => @project.id)
  end

  def blacklist(attachment)
    HelpdeskAttachmentBlacklist.create!(
      :project_id   => @project.id,
      :digest       => HelpdeskAttachmentBlacklist.digest_for(attachment),
      :filename     => attachment.filename,
      :filesize     => attachment.filesize,
      :content_type => attachment.content_type,
      :user_id      => User.current.id,
      :created_on   => Time.current
    )
  end

  def set_description(text)
    Issue.where(:id => @issue.id).update_all(:description => text)
    @issue.reload
  end

  def attach_png(container, filename = 'image001.png')
    attach(container, filename, 'image/png', Base64.decode64(PNG_BASE64))
  end

  def attach_other_png(container, filename)
    attach(container, filename, 'image/png', Base64.decode64(OTHER_PNG_BASE64))
  end

  # A reply the way Redmine builds one: the attachment hangs on the issue and is
  # journalized onto the note, which is what MailHandler produces for a reply mail
  # and what Journal#attachments reads.
  def reply_with_attachment(filename)
    @issue.init_journal(User.find(2), 'Reply')
    @issue.save_attachments('1' => { 'file' => upload(filename, Base64.decode64(PNG_BASE64)) })
    @issue.save!
    @issue.current_journal
  end

  def upload(filename, body, content_type = 'image/png')
    io = StringIO.new(body)
    io.define_singleton_method(:original_filename) { filename }
    io.define_singleton_method(:content_type) { content_type }
    io
  end

  def attach_text(container, filename, body)
    attach(container, filename, 'text/plain', body)
  end

  def attach(container, filename, content_type, body)
    attachment = Attachment.create!(:container => container,
                                    :file => upload(filename, body, content_type),
                                    :author => User.find(2))
    container.reload
    attachment
  end
end
