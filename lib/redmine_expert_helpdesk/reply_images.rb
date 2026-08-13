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

      # Only touch src attributes containing the filename, and never rewrite an
      # already resolved reference (cid:, data:, http:) a second time.
      def replace_src(html, att)
        safe_fn = Regexp.escape(att.filename.to_s)
        return html if safe_fn.empty?

        html.gsub(/(src=)(["'])([^"']*#{safe_fn}[^"']*)\2/i) do
          quote = Regexp.last_match(2)
          value = Regexp.last_match(3)
          if value.match?(%r{\A(cid:|data:|https?:)}i)
            Regexp.last_match(0)
          else
            "#{Regexp.last_match(1)}#{quote}#{yield}#{quote}"
          end
        end
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
