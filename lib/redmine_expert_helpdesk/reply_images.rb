# Bilder einer ausgehenden Kundenantwort im HTML-Body aufloesen.
#
# Das Notizfeld enthaelt Wiki-Markup; der Formatter macht daraus ein
# <img src="dateiname.png"> mit einem *relativen* Pfad. In einer E-Mail bedeutet
# ein solcher Pfad nichts — das Bild muss entweder als CID-Teil mitgeschickt
# (Graph/eigener SMTP-Server) oder als data:-URI eingebettet werden (globaler
# SMTP-Versand). Diese Klasse macht beides und bestimmt vor allem, *welche*
# Anhaenge dafuer ueberhaupt in Frage kommen.
#
# Gegenstueck fuer die eingehende Richtung: RedmineExpertHelpdesk::InlineImages.
module RedmineExpertHelpdesk
  class ReplyImages
    class << self
      # Anhaenge, deren Dateiname im HTML auftauchen darf.
      #
      # pending sind frisch eingefuegte, noch nicht gespeicherte Uploads; sie
      # stehen vorn, damit ein gerade eingefuegtes Bild einen gleichnamigen
      # aelteren Ticket-Anhang schlaegt. Dazu kommen die Bild-Anhaenge des
      # Tickets selbst — genau die referenziert ein Zitat der urspruenglichen
      # Mail (`![](image001.png)`), und ohne sie blieb das Bild beim Kunden leer.
      def candidates(issue, pending)
        list = Array(pending) + issue.attachments.select { |a| image?(a) }
        list.uniq { |a| a.id || a.object_id }
      end

      # Ersetzt src="dateiname" durch cid:... und liefert [{att => cid}, html].
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

      # Ersetzt src="dateiname" durch eine data:-URI und liefert
      # [html, eingebettete_anhaenge].
      def to_data_uri(html, candidates)
        processed = html.to_s.dup
        embedded  = []

        Array(candidates).each do |att|
          next unless att.diskfile && File.exist?(att.diskfile)

          data_uri = "data:#{mime_type(att)};base64,#{Base64.strict_encode64(File.binread(att.diskfile))}"
          replaced = replace_src(processed, att) { data_uri }
          next if replaced == processed

          processed = replaced
          embedded << att
        end
        [processed, embedded]
      end

      private

      # Nur src-Attribute anfassen, die den Dateinamen enthalten, und niemals
      # bereits aufgeloeste Verweise (cid:, data:, http:) erneut ersetzen.
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
