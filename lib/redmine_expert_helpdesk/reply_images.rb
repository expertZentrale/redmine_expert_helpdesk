# Resolves the images of an outgoing customer reply in the HTML body.
#
# The note field holds wiki markup, and the formatter turns it into an
# <img src="filename.png"> with a *relative* path. That path means nothing in an
# email, so the image has to be either sent as a CID part (Graph / the mailbox's
# own SMTP server) or embedded as a data: URI (global SMTP delivery). This class
# does both, and above all decides *which* attachments are eligible.
#
# Counterpart for the incoming direction: RedmineExpertHelpdesk::InlineImages.
module RedmineExpertHelpdesk
  class ReplyImages
    class << self
      # Attachments whose filename may appear in the HTML.
      #
      # `pending` are freshly inserted, not yet saved uploads; they come first so
      # a just-pasted image beats an older ticket attachment of the same name.
      # Added to those are the ticket's own image attachments — exactly what a
      # quote of the original mail refers to (`![](image001.png)`), and without
      # them the customer received an empty box.
      def candidates(issue, pending)
        list = Array(pending) + issue.attachments.select { |a| image?(a) }
        list.uniq { |a| a.id || a.object_id }
      end

      # Replaces src="filename" with cid:... and returns [{att => cid}, html].
      def to_cid(html, candidates)
        cid_map   = {}
        processed = html.to_s.dup

        Array(candidates).each_with_index do |att, i|
          cid      = "img#{att.id}x#{i}@helpdesk.local"
          replaced = replace_src(processed, att) { "cid:#{cid}" }
          next if replaced == processed

          cid_map[att] = cid
          processed    = replaced
        end
        [cid_map, processed]
      end

      # Replaces src="filename" with a data: URI and returns
      # [html, embedded_attachments].
      def to_data_uri(html, candidates)
        processed = html.to_s.dup
        embedded  = []

        Array(candidates).each do |att|
          next unless att.diskfile && File.exist?(att.diskfile)

          # Read and encode inside the block: it only runs on an actual match, so
          # an attachment the body never references is not loaded from disk at
          # all. Memoized because the block runs once per occurrence.
          data_uri = nil
          replaced = replace_src(processed, att) do
            data_uri ||= "data:#{mime_type(att)};base64," \
                         "#{Base64.strict_encode64(File.binread(att.diskfile))}"
          end
          next if replaced == processed

          processed = replaced
          embedded << att
        end
        [processed, embedded]
      end

      private

      # A src that carries a download path names its attachment by id.
      DOWNLOAD_PATH = %r{/attachments/download/\d+/}i

      # Two passes, precise one first.
      #
      # The file name is not an identity: Outlook calls every embedded image
      # "image.png", so a quote of such a mail holds several src attributes that
      # all contain that name but point at different files by id. Matching on the
      # name alone let the first candidate claim all of them - the customer then
      # received one picture as many times as the mail had images, which is the
      # incoming bug over again in the outgoing direction.
      def replace_src(html, att, &block)
        by_path = replace_by_path(html, att, &block)
        replace_by_name(by_path, att, &block)
      end

      # src="/attachments/download/<id>/whatever.png" - only this attachment's id.
      # The trailing slash keeps id 65 out of 653895.
      def replace_by_path(html, att)
        return html if att.id.blank?

        html.gsub(%r{(src=)(["'])([^"']*/attachments/download/#{att.id}/[^"']*)\2}i) do
          rewrite_match(Regexp.last_match) { yield }
        end
      end

      # Anything else naming the file - a freshly pasted upload the agent inserted
      # as "![](image.png)", which has no id yet. A src that does carry a download
      # path is deliberately skipped here: it belongs to whichever attachment the
      # id names, not to the first candidate that shares the file name.
      def replace_by_name(html, att)
        safe_fn = Regexp.escape(att.filename.to_s)
        return html if safe_fn.empty?

        html.gsub(/(src=)(["'])([^"']*#{safe_fn}[^"']*)\2/i) do
          match = Regexp.last_match
          next match[0] if match[3].match?(DOWNLOAD_PATH)

          rewrite_match(match) { yield }
        end
      end

      # Never rewrite an already resolved reference (cid:, data:, http:) a second
      # time. The match is passed in rather than read from Regexp.last_match here:
      # $~ is frame-local, so a method called from the gsub block sees nothing.
      def rewrite_match(match)
        return match[0] if match[3].match?(%r{\A(cid:|data:|https?:)}i)

        "#{match[1]}#{match[2]}#{yield}#{match[2]}"
      end

      def mime_type(att)
        att.content_type.presence ||
          Redmine::MimeType.of(att.filename) ||
          'application/octet-stream'
      end

      def image?(att)
        mime_type(att).to_s.start_with?('image/')
      end
    end
  end
end
