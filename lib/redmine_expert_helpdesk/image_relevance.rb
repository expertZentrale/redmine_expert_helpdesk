# Relevance filter for images handed to the AI (vision) model.
#
# Nearly every business mail carries images that are not evidence: signature
# logos, social-media icons, tracking pixels and spacer GIFs. Sending them to a
# vision model costs tokens for nothing and, worse, competes for the small
# per-request image budget (HelpdeskAiSummaryJob::MAX_IMAGES) with the screenshot
# the agent actually needs.
#
# Two stages, both with a lower bound:
# - byte floor: filesize below the per-project ai_min_image_kb.
# - pixel floor: width or height below MIN_IMAGE_WIDTH/HEIGHT. Catches the large-but-empty
#   tracking pixel and the padded spacer that pass the byte floor.
#
# Every stage KEEPS the image when its signal is unavailable (size 0, unreadable
# header, unknown format). A filter that guesses wrong must lose the logo, never
# the screenshot.
#
# The class is pure (no DB, no HTTP, no mail) except for reading the image header
# from a path it is given, so it is testable without a Redmine environment. The
# third stage of the filter - recurring signature logos, which needs the database -
# lives in HelpdeskAiSummaryJob.
module RedmineExpertHelpdesk
  class ImageRelevance
    # Same reasoning and same default as CompletenessCheck::DEFAULT_MIN_ATTACHMENT_KB,
    # but a separate setting: the completeness check asks "did the customer send
    # evidence at all", this one asks "is it worth paying vision tokens for".
    DEFAULT_MIN_IMAGE_KB = 15

    # Below this an image cannot carry a readable screenshot or a recognisable photo.
    MIN_IMAGE_WIDTH  = 64
    MIN_IMAGE_HEIGHT = 64

    # Guard against a malformed JPEG sending the segment walk into a long loop.
    MAX_JPEG_SEGMENTS = 128

    IMAGE_EXTENSIONS = %w[.png .jpg .jpeg .gif .bmp .webp .heic].freeze

    class << self
      # Returns the attachments worth sending, in input order. Non-images are
      # dropped (this list feeds the vision payload, nothing else).
      def relevant_images(attachments, setting = nil)
        min_bytes = min_image_kb(setting) * 1024

        Array(attachments).select do |a|
          next false unless image?(a)
          next false if too_small_in_bytes?(a, min_bytes)
          next false if too_small_in_pixels?(a)

          true
        end
      end

      def min_image_kb(setting)
        return DEFAULT_MIN_IMAGE_KB unless setting.respond_to?(:ai_min_image_kb)

        value = setting.ai_min_image_kb
        # nil => default; 0 deliberately switches the floor off.
        value.nil? ? DEFAULT_MIN_IMAGE_KB : value.to_i
      end

      def image?(attachment)
        type = attachment.respond_to?(:content_type) ? attachment.content_type.to_s : ''
        return true if type.downcase.start_with?('image/')
        return false if type.present?

        # No content type reported: decide by file extension.
        name = attachment.respond_to?(:filename) ? attachment.filename.to_s : ''
        name.downcase.end_with?(*IMAGE_EXTENSIONS)
      end

      # [width, height] or nil when the format is unknown or the header unreadable.
      # Reads only the leading bytes - no gem, no ImageMagick, no full decode.
      def dimensions(path)
        return nil if path.blank?

        File.open(path, 'rb') do |io|
          head = io.read(30).to_s
          next nil if head.empty?

          case head
          when /\A\x89PNG\r\n\x1a\n/n then png_dimensions(head)
          when /\AGIF8/n              then gif_dimensions(head)
          when /\ABM/n                then bmp_dimensions(head)
          when /\ARIFF.{4}WEBP/nm     then webp_dimensions(io, head)
          when /\A\xff\xd8/n          then jpeg_dimensions(io)
          end
        end
      rescue StandardError
        # An unreadable file must never break the summary - treat it as unknown.
        nil
      end

      private

      def too_small_in_bytes?(attachment, min_bytes)
        return false unless min_bytes.positive?

        size = attachment.respond_to?(:filesize) ? attachment.filesize.to_i : 0
        # Unknown size (0/nil) => keep it when in doubt, never discard.
        size.positive? && size < min_bytes
      end

      def too_small_in_pixels?(attachment)
        path = attachment.respond_to?(:diskfile) ? attachment.diskfile : nil
        return false if path.blank? || !File.exist?(path)

        width, height = dimensions(path)
        # Unknown dimensions => keep.
        return false if width.nil? || height.nil?

        width < MIN_IMAGE_WIDTH || height < MIN_IMAGE_HEIGHT
      end

      # IHDR is always the first chunk: width/height as big-endian uint32 at offset 16.
      def png_dimensions(head)
        return nil if head.bytesize < 24

        head[16, 8].unpack('N2')
      end

      # Logical screen descriptor: little-endian uint16 pair at offset 6.
      def gif_dimensions(head)
        return nil if head.bytesize < 10

        head[6, 4].unpack('v2')
      end

      # BITMAPINFOHEADER: signed little-endian int32 pair at offset 18. Height is
      # negative for top-down bitmaps, so compare on the magnitude.
      def bmp_dimensions(head)
        return nil if head.bytesize < 26

        head[18, 8].unpack('l<2').map(&:abs)
      end

      # Three container variants share the RIFF/WEBP wrapper; the canvas size sits
      # in the first chunk, which starts at offset 12.
      def webp_dimensions(io, _head)
        io.seek(12)
        chunk = io.read(18).to_s
        return nil if chunk.bytesize < 18

        case chunk[0, 4]
        when 'VP8 ' # lossy: 14-bit width/height after the 3-byte sync code
          w, h = chunk[14, 4].unpack('v2')
          [w & 0x3fff, h & 0x3fff]
        when 'VP8L' # lossless: two 14-bit values minus one, packed after the signature
          bits = chunk[9, 4].unpack1('V')
          [(bits & 0x3fff) + 1, ((bits >> 14) & 0x3fff) + 1]
        when 'VP8X' # extended: two 24-bit values minus one
          [le24(chunk[12, 3]) + 1, le24(chunk[15, 3]) + 1]
        end
      end

      def le24(bytes)
        b = bytes.unpack('C3')
        b[0] | (b[1] << 8) | (b[2] << 16)
      end

      # Walks the marker segments to the first Start-Of-Frame, which carries the
      # size. Stops at SOS (compressed data begins) or EOI.
      def jpeg_dimensions(io)
        io.seek(2)
        MAX_JPEG_SEGMENTS.times do
          marker = next_marker(io)
          return nil if marker.nil?
          return nil if [0xda, 0xd9].include?(marker) # SOS / EOI - no SOF seen
          next if standalone?(marker)                 # no length field follows

          length = io.read(2).to_s.unpack1('n')
          return nil if length.nil? || length < 2

          if sof?(marker)
            frame = io.read(5).to_s
            return nil if frame.bytesize < 5

            height, width = frame[1, 4].unpack('n2')
            return [width, height]
          end

          io.seek(length - 2, IO::SEEK_CUR)
        end
        nil
      end

      # Every segment starts with 0xff; a run of 0xff bytes is padding.
      def next_marker(io)
        byte = io.read(1)
        byte = io.read(1) while byte && byte != "\xff".b
        return nil if byte.nil?

        byte = io.read(1) while byte == "\xff".b
        byte&.unpack1('C')
      end

      # SOI, TEM and the restart markers carry no length field.
      def standalone?(marker)
        marker == 0x01 || marker == 0xd8 || marker.between?(0xd0, 0xd7)
      end

      # SOF0-SOF15 minus the non-frame markers DHT (c4), JPG (c8) and DAC (cc).
      def sof?(marker)
        marker.between?(0xc0, 0xcf) && ![0xc4, 0xc8, 0xcc].include?(marker)
      end
    end
  end
end
