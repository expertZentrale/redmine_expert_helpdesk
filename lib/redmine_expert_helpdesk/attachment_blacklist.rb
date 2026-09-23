# Drops attachments whose file content an agent has blacklisted.
#
# Nearly every business mail carries the sender's signature logo, a row of
# social-media icons and a tracking pixel, and MailHandler stores each one as a
# real attachment. A thread of ten mails therefore ends with thirty files on the
# ticket, none of them evidence. ImageRelevance already keeps them away from the
# vision model and CompletenessCheck ignores them, but the ticket still shows
# them - this module removes them for good.
#
# Two entry points, one rule (HelpdeskAttachmentBlacklist#digest, the SHA-256 of
# the bytes, scoped to the project):
#
#   filter!(object, issue) - during ingestion, right after MailHandler stored the
#                            mail's attachments and InlineImages linked them.
#   purge!(project, entry) - retroactively, when an agent blacklists a file: every
#                            copy already sitting on a ticket of that project goes.
#
# Deleting the file is only half of it. InlineImages has by then turned the mail's
# "[cid:…]" markers into image syntax pointing at the attachment, so dropping the
# file alone would trade a signature logo for a broken image. Every delete
# therefore strips the markup that named it, past the callbacks (see
# InlineImages.store_text): this is cleanup, not an agent's edit, and must not
# produce a journal entry or a notification for text the customer wrote.
module RedmineExpertHelpdesk
  module AttachmentBlacklist
    # What the "block" button may be offered for. Blacklisting deletes a file from
    # every ticket of the project, so the button must not sit next to the evidence:
    # an .eml, a .msg, a PDF, a log. The default is therefore an allow list of the
    # image formats signature logos and icons actually come in - everything else has
    # to be named deliberately.
    #
    # These constants are the real floor, not init.rb's :default hash: a key added
    # there reads nil on every install whose settings form has not been saved since,
    # and a nil allow list would put the button on every attachment there is.
    DEFAULT_TYPES = 'png, gif, jpg, jpeg, bmp, webp, tif, tiff, ico'.freeze

    # A signature logo is the largest thing worth blocking; a screenshot starts
    # above this. 0 turns the size guard off.
    DEFAULT_MAX_KB = 100

    # Lets an administrator hand the decision back to the agents entirely.
    ANY_TYPE = '*'.freeze

    module_function

    # May this attachment be blacklisted at all? Checked when the button is drawn
    # and again when it is used - the page may have been open since the settings
    # changed, and the request does not have to come from the page.
    # +setting+ is optional so a caller checking a whole ticket can resolve the
    # project's settings once instead of per attachment.
    def eligible?(attachment, project, setting = nil)
      return false if attachment.nil? || project.nil?

      setting ||= HelpdeskProjectSetting.for_project(project)
      size_allowed?(attachment, setting) && type_allowed?(attachment, setting)
    end

    # The ids of the attachments on this ticket the button may be drawn for.
    #
    # Decided server-side and handed to the script as a list, rather than giving the
    # script the rules: the row's size is rendered as "(139 Bytes)" in the user's
    # locale, and re-parsing that to enforce a limit would be guesswork.
    def eligible_ids(issue)
      return [] if issue.nil?

      project = issue.project
      # One settings lookup for the whole ticket: for_project does a
      # find_or_initialize_by, and a mail thread can leave dozens of rows to check
      # while the page renders.
      setting = HelpdeskProjectSetting.for_project(project)
      rendered_attachments(issue).select { |a| eligible?(a, project, setting) }.map(&:id)
    end

    def rendered_attachments(issue)
      Attachment.where(:container_type => 'Issue', :container_id => issue.id)
                .or(Attachment.where(:container_type => 'Journal',
                                     :container_id => issue.journals.select(:id)))
                .to_a
    end

    def size_allowed?(attachment, setting)
      max_kb = setting.effective_blacklist_max_kb
      return true unless max_kb.positive?

      attachment.filesize.to_i <= max_kb * 1024
    end

    # An entry naming a MIME type carries a slash ("image/gif", "image/*"), anything
    # else is a file extension ("gif"). Both are needed: extensions are what the
    # setting's readers think in, but plenty of mail clients label every attachment
    # application/octet-stream or send none with a usable name at all.
    def type_allowed?(attachment, setting)
      rules = parse_types(setting.effective_blacklist_types)
      return true if rules.include?(ANY_TYPE)
      return false if rules.empty?

      extension = File.extname(attachment.filename.to_s).delete('.').downcase
      content_type = attachment.content_type.to_s.downcase.strip

      rules.any? do |rule|
        rule.include?('/') ? mime_match?(content_type, rule) : (extension.present? && extension == rule)
      end
    end

    def parse_types(raw)
      raw.to_s.downcase.split(/[,;\s]+/).map { |t| t.strip.delete_prefix('.') }.reject(&:blank?)
    end

    def mime_match?(content_type, rule)
      return false if content_type.blank?
      return content_type.start_with?(rule.delete_suffix(ANY_TYPE)) if rule.end_with?("/#{ANY_TYPE}")

      content_type == rule
    end

    # Removes the blacklisted attachments the mail has just brought. +object+ is
    # what MailHandler returned - an Issue for a new ticket, a Journal for a reply.
    # Returns the number of dropped files.
    def filter!(object, issue)
      project = issue.try(:project)
      return 0 if project.nil?

      entries = HelpdeskAttachmentBlacklist.where(:project_id => project.id).to_a
      return 0 if entries.empty?

      dropped = incoming_attachments(object, issue).count do |attachment|
        entry = entry_for(entries, attachment)
        next false if entry.nil?

        drop!(attachment, object)
        entry.register_hit!
        true
      end

      if dropped.positive?
        Rails.logger.info "Helpdesk: #{dropped} blacklisted attachment(s) dropped from " \
                          "#{object.class.name} ##{object.id}"
      end
      dropped
    rescue StandardError => e
      # A signature logo is never worth losing a ticket over.
      Rails.logger.warn "Helpdesk: attachment blacklist filter failed: #{e.message}"
      0
    end

    # Every copy of the blacklisted content already stored on a ticket of this
    # project - on the issue itself or on one of its journals. Returns the number
    # of deleted files.
    def purge!(project, entry)
      matching_attachments(project, entry).count do |attachment|
        drop!(attachment, containers_of(attachment))
        true
      end
    end

    # What purge! would delete, without deleting it, so the agent confirms against
    # a real number.
    def count_copies(project, entry)
      matching_attachments(project, entry).size
    end

    # --- matching ---------------------------------------------------------------

    # The entry out of +entries+ covering this attachment, or nil.
    #
    # File size decides first, because it is already loaded on both sides while the
    # digest costs a read of the file: most mails carry only attachments no entry
    # could possibly match, and those must not be hashed at all. Identical bytes
    # always have an identical size, so the shortcut can lose no match. An entry
    # with no size recorded stays a candidate for everything.
    def entry_for(entries, attachment)
      sized, unsized = entries.partition { |e| e.filesize.to_i.positive? }
      candidates = sized.select { |e| e.filesize.to_i == attachment.filesize.to_i } + unsized
      return nil if candidates.empty?

      digest = HelpdeskAttachmentBlacklist.digest_for(attachment)
      return nil if digest.blank?

      candidates.find { |e| e.digest == digest }
    end

    # Candidates are narrowed by file size in SQL first - the digest itself is not
    # stored by us and Redmine's own column cannot be trusted for it (see
    # HelpdeskAttachmentBlacklist.digest_for), so every remaining candidate has to
    # be read from disk. A signature logo has a distinctive size, so this leaves a
    # handful of files rather than the project's whole attachment table.
    def matching_attachments(project, entry)
      return [] if project.nil? || entry.nil?

      scope = project_attachments(project)
      scope = scope.where(:filesize => entry.filesize) if entry.filesize.to_i.positive?
      scope.select { |a| HelpdeskAttachmentBlacklist.digest_for(a) == entry.digest }
    end

    def project_attachments(project)
      issues = Issue.where(:project_id => project.id).select(:id)
      journals = Journal.where(:journalized_type => 'Issue', :journalized_id => issues).select(:id)

      Attachment.where(:container_type => 'Issue', :container_id => issues)
                .or(Attachment.where(:container_type => 'Journal', :container_id => journals))
    end

    # --- deletion ---------------------------------------------------------------

    # Strips the markup naming the file, then deletes it. In that order, because
    # the markup is built from the attachment's id and name.
    #
    # Attachment#destroy on its own does not journalize - Redmine's
    # AttachmentsController calls init_journal before it, we deliberately do not.
    def drop!(attachment, containers)
      Array(containers).each { |container| strip_references!(container, attachment) }
      attachment.destroy
    end

    # Every text that may show this attachment.
    #
    # Not simply Attachment#container: MailHandler files a *reply's* attachments on
    # the issue and journalizes them onto the note it just created, so the markup
    # InlineImages wrote for them sits in that note while the container is the
    # issue. Cleaning only the container would delete the file and leave the note
    # showing a broken image - which is the whole thing this feature exists to
    # avoid. The owning notes are found through the journal detail that records the
    # attachment, so unrelated notes are left alone.
    def containers_of(attachment)
      container = attachment.container
      return [container] unless container.is_a?(Issue)

      [container] + owning_journals(container, attachment)
    end

    def owning_journals(issue, attachment)
      Journal.joins(:details)
             .where(:journalized_type => 'Issue', :journalized_id => issue.id)
             .where(:journal_details => { :property => 'attachment',
                                          :prop_key => attachment.id.to_s })
             .distinct
             .to_a
    end

    # Removes the image syntax pointing at +attachment+ from the text of its
    # container. Returns true when the text was changed.
    def strip_references!(container, attachment)
      text = InlineImages.stored_text(container)
      return false if text.blank?

      cleaned = markup_targets(attachment, container)
                .inject(text) { |current, t| remove_target(current, t) }
      # Nothing of this file was named here - leave the text exactly as it is
      # rather than rewriting it for the whitespace pass below.
      return false if cleaned == text

      # A marker that sat alone on its line leaves the blank line behind.
      cleaned = cleaned.gsub(/\n{3,}/, "\n\n").strip
      InlineImages.store_text(container, cleaned)
    end

    # Everything the markup may name the file by: the download path (InlineImages
    # falls back to it for a journal without own attachment details) and the plain
    # file name, each also in the percent-escaped spelling InlineImages writes.
    #
    # The download path carries the id and so names exactly this file. The bare file
    # name does not - Redmine resolves it against the whole container, and
    # "image001.png" is what every Outlook numbers its first embedded image. Where a
    # sibling shares the name it is therefore left alone: stripping it would blank
    # the markup of a screenshot that merely happens to be called image001.png too,
    # and after the delete that markup simply resolves to the sibling instead.
    def markup_targets(attachment, container)
      name = attachment.filename.to_s
      return [] if name.blank?

      spellings = [name, InlineImages.escape_target(name)].uniq
      targets = spellings.map { |s| "/attachments/download/#{attachment.id}/#{s}" }
      targets += spellings unless name_shared?(attachment, container)
      targets
    end

    # Does another attachment Redmine would resolve this text against carry the same
    # file name? Compared case-insensitively, the way Redmine's own lookup does.
    def name_shared?(attachment, container)
      siblings = InlineImages.attachment_scope(container)
      name = attachment.filename.to_s
      siblings.any? { |a| a.id != attachment.id && a.filename.to_s.casecmp(name).zero? }
    rescue StandardError
      # Unable to tell - assume it is shared and only strip the unambiguous form.
      true
    end

    def remove_target(text, target)
      quoted = Regexp.escape(target)

      # Raw HTML that survived into the body - the whole tag goes, not just the src.
      result = text.gsub(/<img\b[^>]*\bsrc\s*=\s*["']#{quoted}["'][^>]*>/i, '')
      # Markdown, with or without alt text.
      result = result.gsub(/!\[[^\]]*\]\(\s*#{quoted}\s*\)/i, '')
      # Textile, optionally with alignment/style prefix and title suffix.
      result.gsub(/!(?:[<>=]|\{[^}]*\})*#{quoted}(?:\([^)]*\))?!/i, '')
    end

    # --- ingestion scope ---------------------------------------------------------

    # What this mail brought, and nothing else. MailHandler appends a reply's
    # attachments to the issue and journalizes them onto the journal it created, so
    # a reply's own files are reachable from the journal. Unlike InlineImages there
    # is deliberately no fallback to the issue's attachments for a journal without
    # its own: that would delete files an earlier mail brought, from an ingestion
    # run that has no business touching them.
    def incoming_attachments(object, issue)
      return Array(object.attachments) if object.is_a?(Journal)

      Array(issue.try(:attachments))
    end
  end
end
