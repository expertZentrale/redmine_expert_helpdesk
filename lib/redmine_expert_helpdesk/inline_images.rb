# Inline images (CID) of incoming mails.
#
# Redmine's MailHandler stores every embedded image of a mail as a regular
# attachment, but the body it keeps is text: the picture itself is gone and only
# the reference the mail client left behind survives, e.g.
# "[cid:image001.png@01DD2980.37ED1560]" (Outlook/Exchange) or "[image: logo.png]"
# (Gmail). The ticket then shows those markers where the mail showed a picture.
#
# This module turns the markers into Redmine image syntax pointing at the
# attachment MailHandler has just saved, so the ticket renders like the original
# mail. Two entry points around MailHandler.receive, both no-ops when there is
# nothing to do:
#
#   prepare_mime(mime)     - before: needed only when Redmine keeps the HTML part
#                            (its HTML-to-text parser has no rule for <img>, so
#                            the reference would be dropped without a trace).
#                            Rewrites <img src="cid:x"> to the same [cid:x] marker
#                            a text body carries, so one rewrite pass fits both.
#   rewrite!(object, mime) - after: replaces the markers in the issue description
#                            (new ticket) resp. the journal note (reply).

require 'digest'

module RedmineExpertHelpdesk
  module InlineImages
    # File extensions Redmine resolves against the attachments of the object it
    # renders (application_helper.rb, parse_inline_attachments). For anything else
    # the markup would stay a dead link, so those markers are left alone.
    INLINE_EXTENSIONS = %w[bmp gif jpg jpe jpeg png webp].freeze

    # Every marker form carries its reference - a Content-ID or a file name - in
    # capture group 1.
    IMG_TAG     = /<img\b[^>]*\bsrc\s*=\s*["']cid:([^"']+)["'][^>]*>/i               # raw HTML
    MD_IMAGE    = /!\[[^\]]*\]\(\s*cid:([^)\s]+)\s*\)/i                              # markdown
    TEXTILE_IMG = /!\s*cid:([^!\s]+)\s*!/i                                           # textile
    BRACKET_CID = /\[\s*cid:\s*([^\]\s]+)\s*\]/i                                     # Outlook text body
    GMAIL_IMAGE = /\[image:\s*([^\]]+?)\s*\]/i                                       # Gmail text body
    SRC_CID     = /src\s*=\s*["']cid:([^"']+)["']/i                                  # HTML attribute

    # Markers that stand on their own in the text; they are replaced by image syntax.
    TEXT_PATTERNS = [MD_IMAGE, TEXTILE_IMG, BRACKET_CID, GMAIL_IMAGE].freeze

    # Cheap pre-check so mails without any embedded image never parse their MIME
    # a second time.
    ANY_MARKER = /cid:|\[image:/i

    # The same idea before the MIME is parsed at all: without a Content-ID header
    # there is no part a cid: reference could resolve to. Matched on the raw bytes -
    # a MIME string straight from the provider is rarely valid UTF-8, and the body
    # of the mail is not worth decoding just to find that out.
    CONTENT_ID_HEADER = /^content-id:/i

    module_function

    def enabled?
      Setting.plugin_redmine_expert_helpdesk['inline_images_enabled'].to_s != '0'
    end

    # Replaces the CID markers in the text MailHandler stored for +object+ (an
    # Issue for a new ticket, a Journal for a reply) with image syntax.
    # Returns true when the text was changed.
    def rewrite!(object, mime)
      return false unless enabled?

      text = stored_text(object)
      return false if text.blank? || text !~ ANY_MARKER

      attachments = attachment_scope(object)
      return false if attachments.empty?

      index = cid_index(Mail.read_from_string(mime), attachments)
      return false if index.empty?

      rewritten = replace_markers(text, index)
      return false if rewritten == text

      unless store_text(object, rewritten)
        Rails.logger.warn "Helpdesk: inline images of #{object.class.name} ##{object.id} " \
                          'could not be stored'
        return false
      end

      Rails.logger.info "Helpdesk: #{index.values.uniq.size} inline image(s) linked in " \
                        "#{object.class.name} ##{object.id}"
      true
    rescue StandardError => e
      Rails.logger.warn "Helpdesk: inline image rewrite failed: #{e.message}"
      false
    end

    # Turns <img src="cid:..."> into the [cid:...] marker a text body carries, but
    # only when Redmine will actually keep the HTML part - otherwise the text/plain
    # alternative is used and already holds the markers.
    #
    # Only the copy handed to MailHandler is touched; the caller keeps the original
    # MIME, which is what gets archived as .eml on the ticket.
    def prepare_mime(mime)
      return mime unless enabled? && mime.to_s.b.match?(CONTENT_ID_HEADER)

      mail = Mail.read_from_string(mime)
      return mime unless html_body_kept?(mail)

      changed = false
      html_parts(mail).each { |part| changed = true if mark_images(part) }
      changed ? mail.to_s : mime
    rescue StandardError => e
      Rails.logger.warn "Helpdesk: inline image preprocessing failed: #{e.message}"
      mime
    end

    # --- text of the created object -----------------------------------------

    def stored_text(object)
      if object.is_a?(Journal)
        object.notes
      elsif object.respond_to?(:description)
        object.description
      end
    end

    # Writes the text past the callbacks: this is not a user edit, so it must not
    # produce a journal, an "edited" marker or a notification for a text the
    # customer wrote.
    #
    # update_all, not update_columns: Rails adds the record's lock_version to the
    # WHERE clause of update_columns, and the instance MailHandler returns is
    # already a version behind - it saves the issue again while storing the mail's
    # attachments - so the write silently matched no row (and reported no error).
    # The lock_version is deliberately left untouched: bumping it would turn the
    # next save of any instance still in flight into a StaleObjectError.
    # Returns true when the row was actually written.
    def store_text(object, text)
      column = object.is_a?(Journal) ? :notes : :description
      updated = object.class.where(:id => object.id).update_all(column => text) == 1
      object[column] = text if updated
      updated
    end

    # The attachments this mail's parts are matched against, newest first so that a
    # file name repeated across mails (image001.png in a signature) prefers this
    # mail's copy when nothing else tells them apart.
    #
    # MailHandler appends mail attachments to the issue, whose after_add hook
    # journalizes them onto the journal it has just created - so a reply's images
    # are reachable from both. Returns the attachments alone: the markup names the
    # download path in every case now, so whether a bare file name would resolve
    # here no longer makes a difference.
    def attachment_scope(object)
      if object.is_a?(Journal)
        own = object.respond_to?(:attachments) ? object.attachments.to_a : []
        return newest_first(own) if own.any?

        newest_first(Array(object.journalized.try(:attachments)))
      else
        newest_first(Array(object.try(:attachments)))
      end
    end

    def newest_first(attachments)
      attachments.sort_by { |a| -a.id.to_i }
    end

    # --- CID map --------------------------------------------------------------

    # Maps everything a marker may name - the Content-ID and the file name of an
    # embedded image - onto the attachment Redmine stored for it.
    #
    # Each part claims its attachment, so a mail whose images all carry the same file
    # name still maps every Content-ID to a different file. Outlook names every
    # embedded image "image.png": a signature with a logo, a phone icon, a mail icon
    # and four social icons arrives as seven parts with seven Content-IDs and one
    # name between them, and matching on the name alone handed all seven the same
    # attachment - the ticket then showed the same picture seven times.
    def cid_index(mail, attachments)
      index = {}
      claimed = []

      mail.attachments.each do |part|
        name = part.filename.to_s
        next unless inline_image?(name)

        attachment = find_attachment(attachments, part, claimed)
        next unless attachment

        claimed << attachment.id
        cid = part.content_id.to_s.gsub(/\A<|>\z/, '').strip
        index[index_key(cid)] = attachment if cid.present?
        # The bare name is kept only as a last resort for markers that carry no
        # Content-ID (Gmail's "[image: logo.png]"); with repeated names it can only
        # ever mean the first part that used it.
        index[index_key(name)] ||= attachment
        index[index_key(attachment.filename)] ||= attachment
      end
      index
    end

    def inline_image?(filename)
      INLINE_EXTENSIONS.include?(filename.to_s.split('.').last.to_s.downcase)
    end

    # The attachment Redmine stored for this MIME part.
    #
    # The name narrows the field, the bytes decide it - and only the bytes. MailHandler
    # hands the part's file name to Attachment, which sanitizes it (path prefixes,
    # characters such as ":" or "?"), so the stored name is not always the one the
    # part carries - compare against both. +claimed+ keeps two parts from taking the
    # same file. Returns nil whenever nothing matches the part's content, so a marker
    # is left unresolved rather than pointed at somebody else's picture.
    def find_attachment(attachments, part, claimed = [])
      candidates = named_like(attachments, part.filename.to_s)
      return nil if candidates.empty?

      # No unclaimed candidate means this part has no file of its own: MailHandler
      # stored fewer images than the mail carries, because one was excluded by size
      # or by "Excluded attachment file names". Handing back an already claimed
      # attachment would show one picture twice - the very fault this pairing
      # exists to prevent - so the marker is left unresolved instead, which is what
      # the module does with every reference it cannot reach.
      pool = candidates.reject { |a| claimed.include?(a.id) }
      return nil if pool.empty?

      bytes = part_bytes(part)
      return nil if bytes.nil?

      # Size first, but only to avoid hashing files that cannot match - identity is
      # the digest. A name is no evidence at all here: attachment_scope reaches the
      # whole issue, so a part MailHandler excluded (too large, or on the excluded
      # names list) would otherwise borrow the "image.png" an *earlier* mail left
      # there and show that mail's picture. Where the bytes do match, pointing at
      # the older row is right anyway - it is the same image.
      sized = pool.select { |a| a.filesize.to_i == bytes.bytesize }
      return nil if sized.empty?

      digest = Digest::SHA256.hexdigest(bytes)
      sized.find { |a| stored_digest(a) == digest }
    end

    def named_like(attachments, name)
      stored = sanitized_filename(name)
      attachments.select do |a|
        a.filename == name || a.filename == stored ||
          a.filename.to_s.casecmp(stored.to_s).zero?
      end
    end

    def part_bytes(part)
      part.body.decoded
    rescue StandardError
      nil
    end

    # Computed rather than read from Attachment#digest: that column held MD5 before
    # Redmine 3.4, so it cannot be compared against a SHA-256 of the part.
    def stored_digest(attachment)
      path = attachment.diskfile
      return nil if path.blank? || !File.exist?(path)

      Digest::SHA256.file(path).hexdigest
    rescue StandardError
      nil
    end

    def sanitized_filename(name)
      Attachment.new(:filename => name).filename
    rescue StandardError
      name
    end

    def index_key(value)
      value.to_s.strip.downcase
    end

    # --- markup ---------------------------------------------------------------

    def replace_markers(text, index)
      # A cid: inside a src attribute belongs to raw HTML that survived into the
      # body: only the value is exchanged, so the tag keeps its size and alt
      # attributes and Redmine resolves the file name while it renders the HTML.
      result = text.gsub(SRC_CID) do |marker|
        attachment = index[index_key(Regexp.last_match(1))]
        attachment ? %(src="#{target(attachment)}") : marker
      end

      TEXT_PATTERNS.inject(result) do |current, pattern|
        current.gsub(pattern) do |marker|
          attachment = index[index_key(Regexp.last_match(1))]
          attachment ? markup(attachment) : marker
        end
      end
    end

    # "!path!" resp. "![](path)" is the image syntax of the configured formatter.
    def markup(attachment)
      link = target(attachment)
      textile? ? "!#{link}!" : "![](#{link})"
    end

    # Always the download path, never the bare file name.
    #
    # A bare name is not a reference to a file, it is a lookup: Redmine resolves it
    # with Attachment.latest_attach against every attachment of the rendered object
    # and takes the newest match. That breaks twice over. Within one mail, Outlook
    # names every embedded image "image.png", so all of them would resolve to
    # whichever was stored last. Across mails it rots - MailHandler appends a reply's
    # attachments to the *issue*, so the description is rendered against them too,
    # and the next mail carrying an "image.png" quietly takes over the markers of the
    # first. The id names exactly one file and keeps doing so.
    #
    # relative_url_root is included because a sub-URI install serves attachments
    # below it; without it the src would point outside the application.
    def target(attachment)
      "#{Redmine::Utils.relative_url_root}" \
        "/attachments/download/#{attachment.id}/#{escape_target(attachment.filename)}"
    end

    def textile?
      Setting.text_formatting.to_s == 'textile'
    end

    # Characters that would end the image syntax early are percent-encoded; Redmine
    # unescapes the src again before it looks the attachment up. The "%" is in the
    # set so that the encoding stays unambiguous on its own terms - Redmine's
    # Attachment#sanitize_filename happens to replace it with "_" already, but that
    # is its invariant, not ours.
    def escape_target(filename)
      filename.to_s.gsub(/[\s%!()\[\]<>"']/) { |char| format('%%%02X', char.ord) }
    end

    # --- MIME preprocessing ----------------------------------------------------

    # True when MailHandler will build the body from the HTML part: either Redmine
    # is configured to prefer it, or the mail carries no usable text alternative.
    def html_body_kept?(mail)
      return true if Setting.mail_handler_preferred_body_part.to_s == 'html'

      body_parts(mail).none? { |p| p.mime_type == 'text/plain' && decoded_body(p).present? }
    end

    def html_parts(mail)
      body_parts(mail).select { |p| p.mime_type == 'text/html' }
    end

    def body_parts(mail)
      parts = mail.all_parts.presence || [mail]
      parts.reject(&:attachment?)
    end

    def mark_images(part)
      body = decoded_body(part)
      return false if body.blank?

      marked = body.gsub(IMG_TAG) { "[cid:#{Regexp.last_match(1).strip}]" }
      return false if marked == body

      # The body is UTF-8 now, so the part's charset has to say so as well.
      part.body = nil
      part.charset = 'UTF-8'
      part.content_transfer_encoding = 'base64'
      part.body = Mail::Encodings::Base64.encode(marked)
      true
    end

    # Decodes a part to UTF-8 honouring its declared charset (Outlook likes
    # windows-1252); invalid bytes are replaced instead of raising.
    def decoded_body(part)
      body = part.body.decoded.dup
      charset = part.charset.to_s.presence

      if charset && charset.downcase !~ /utf-?8/
        begin
          body.force_encoding(charset)
          body = body.encode('UTF-8', :invalid => :replace, :undef => :replace, :replace => '')
        rescue StandardError
          body.force_encoding('UTF-8')
        end
      else
        body.force_encoding('UTF-8')
      end

      body.scrub('')
    rescue StandardError
      nil
    end
  end
end
