# Prueft eingehende Mails auf bekannte Phishing-URLs (lokaler Feed-Spiegel)
# und neutralisiert Treffer im MIME-Body.
#
# Zusaetzliche Heuristiken fuer verschleierte Links (Warnbox statt Entfernung):
#   - Weiterleitungs-Links: URL traegt eine zweite, url-kodierte Ziel-URL im
#     Query-Parameter (z. B. redirect-url.email/?link=https%3A%2F%2F...)
#   - Kurz-URL-Dienste (bit.ly, tinyurl, ...): Ziel nicht erkennbar
#   - Anchor-Mismatch: sichtbarer Linktext zeigt eine andere Domain als das href-Ziel
#
# Microsoft SafeLinks (*.safelinks.protection.outlook.com) werden lokal
# dekodiert (Original-URL steckt url-encodiert im Query-Parameter "url") –
# es findet kein HTTP-Request statt.
#
# Rueckgabe von scan: { :mime =>, :hits => [...], :suspicions => [...] }
# Treffer:   { :url, :resolved_url, :phish_id, :target, :source_label }
# Verdacht:  { :url, :reason (:redirect|:shortener|:anchor_mismatch), :detail, :label }

require 'cgi'

module RedmineExpertHelpdesk
  class PhishingScanner
    # Grobe URL-Erkennung in Klartext; endgueltige Pruefung erfolgt normalisiert.
    URL_PATTERN = %r{https?://[^\s<>"'\)\]]+}i.freeze

    SAFELINKS_HOST_SUFFIX = '.safelinks.protection.outlook.com'.freeze

    # Bekannte Kurz-URL-/Redirect-Dienste (Ziel nicht erkennbar)
    SHORTENER_DOMAINS = %w[
      bit.ly tinyurl.com t.co goo.gl is.gd ow.ly buff.ly cutt.ly rebrand.ly
      tiny.cc rb.gy shorturl.at s.id t.ly v.gd qr.ae adf.ly rotf.lol lnkiy.com
    ].freeze

    # HTML-Anchor mit absolutem Ziel und sichtbarem Text
    ANCHOR_PATTERN = %r{<a\b[^>]*href\s*=\s*["']?(https?://[^"'\s>]+)["']?[^>]*>(.*?)</a>}im.freeze

    # Domain-artiger Token im sichtbaren Linktext (z. B. "www.paypal.com")
    DOMAIN_IN_TEXT = %r{(?:[a-z0-9][a-z0-9-]*\.)+[a-z]{2,}}i.freeze

    def self.scan(mime)
      new.scan(mime)
    end

    def scan(mime)
      mail = Mail.read_from_string(mime)
      hits = {}
      suspicions = {}
      urls_checked = 0

      parts = scannable_parts(mail)
      Rails.logger.info "Helpdesk/Phishing: Scanne #{parts.size} Mail-Part(s) (#{parts.map { |p| p.content_type.to_s.split(';').first }.join(', ')})"

      parts.each do |part|
        body = decoded_body(part)
        if body.blank?
          Rails.logger.debug "Helpdesk/Phishing: Part #{part.content_type.to_s.split(';').first} hat keinen dekodierbaren Body"
          next
        end

        is_html = part.content_type.to_s =~ %r{text/html}i
        urls = extract_urls(body)
        Rails.logger.info "Helpdesk/Phishing: #{urls.size} URL(s) in #{part.content_type.to_s.split(';').first} gefunden"

        urls.each do |url|
          next if hits.key?(url) || suspicions.key?(url)

          urls_checked += 1
          resolved = resolve_safelink(url)
          if resolved != url
            Rails.logger.info "Helpdesk/Phishing: SafeLink aufgeloest: #{url.truncate(120)} -> #{resolved.truncate(120)}"
          end

          embedded = extract_embedded_url(resolved)

          entry = HelpdeskPhishingUrl.lookup(resolved) || HelpdeskPhishingUrl.lookup(url) ||
                  (embedded && HelpdeskPhishingUrl.lookup(embedded))
          if entry
            source_label = entry.source == 'phishing_database' ? 'Phishing.Database' : "PhishTank ##{entry.phish_id}"
            Rails.logger.warn "Helpdesk/Phishing: TREFFER fuer #{resolved.truncate(200)} (#{source_label})"
            hits[url] = {
              :url          => url,
              :resolved_url => resolved == url ? nil : resolved,
              :phish_id     => entry.phish_id,
              :target       => entry.target,
              :source_label => source_label
            }
          elsif embedded
            Rails.logger.warn "Helpdesk/Phishing: VERDACHT (Weiterleitung) #{url.truncate(120)} -> #{embedded.truncate(120)}"
            suspicions[url] = build_suspicion(url, :redirect, embedded)
          elsif shortener?(resolved)
            Rails.logger.warn "Helpdesk/Phishing: VERDACHT (Kurz-URL) #{resolved.truncate(120)}"
            suspicions[url] = build_suspicion(url, :shortener, nil)
          else
            Rails.logger.debug "Helpdesk/Phishing: kein Treffer fuer #{resolved.truncate(200)} (Hash: #{HelpdeskPhishingUrl.hash_for(resolved)})"
          end
        end

        # Anchor-Mismatch: sichtbarer Linktext zeigt andere Domain als das Ziel
        next unless is_html

        find_anchor_mismatches(body).each do |m|
          next if hits.key?(m[:href]) || suspicions.key?(m[:href])

          Rails.logger.warn "Helpdesk/Phishing: VERDACHT (Linktext-Mismatch) Text zeigt #{m[:shown]}, Ziel ist #{m[:actual]}"
          suspicions[m[:href]] = build_suspicion(m[:href], :anchor_mismatch, "#{m[:shown]} -> #{m[:actual]}")
        end
      end

      Rails.logger.info "Helpdesk/Phishing: Scan abgeschlossen – #{urls_checked} URL(s) geprueft, #{hits.size} Treffer, #{suspicions.size} Verdachtsfaelle"

      return { :mime => mime, :hits => [], :suspicions => [] } if hits.empty? && suspicions.empty?

      parts.each do |part|
        rewrite_part(part, hits, suspicions)
      end

      { :mime => mail.to_s, :hits => hits.values, :suspicions => suspicions.values }
    rescue StandardError => e
      Rails.logger.error "Helpdesk: Phishing-Scan fehlgeschlagen: #{e.message}"
      { :mime => mime, :hits => [], :suspicions => [] }
    end

    # Dekodiert eine SafeLinks-URL zur Original-URL. Nicht-SafeLinks-URLs
    # werden unveraendert zurueckgegeben.
    def resolve_safelink(url)
      uri = URI.parse(url)
      return url unless uri.host&.downcase&.end_with?(SAFELINKS_HOST_SUFFIX)

      original = query_pairs(uri).find { |key, _value| key == 'url' }&.last
      original.presence || url
    rescue URI::Error
      url
    end

    private

    # Liefert die zu scannenden Mail-Parts (text/plain + text/html).
    # Bei nicht-multipart Mails die Mail selbst.
    def scannable_parts(mail)
      if mail.multipart?
        mail.all_parts.select do |p|
          p.content_type.to_s =~ %r{text/(plain|html)}i && !p.attachment?
        end
      else
        [mail]
      end
    end

    # Dekodiert den Part-Body nach UTF-8 unter Beruecksichtigung des deklarierten
    # Charsets (Outlook sendet oft windows-1252/iso-8859-1). Ungueltige Bytes
    # werden ersetzt (scrub), damit der Regex-Scan nicht mit
    # "invalid byte sequence in UTF-8" fehlschlaegt.
    def decoded_body(part)
      body = part.body.decoded.dup
      charset = part.charset.to_s.presence

      if charset && charset.downcase !~ /utf-?8/
        begin
          body.force_encoding(charset)
          body = body.encode('UTF-8', :invalid => :replace, :undef => :replace, :replace => ' ')
        rescue StandardError
          body.force_encoding('UTF-8')
        end
      else
        body.force_encoding('UTF-8')
      end

      body.scrub(' ')
    rescue StandardError
      nil
    end

    def extract_urls(body)
      body.scan(URL_PATTERN).map { |u| u.sub(/[.,;:!?]+\z/, '') }.uniq
    end

    # Extrahiert eine im Query-Parameter eingebettete absolute Ziel-URL
    # (Redirect-/Tracking-Links wie ...?link=https%3A%2F%2Fevil.example%2F).
    # query_pairs dekodiert die Werte bereits. Liefert nil wenn keine vorhanden.
    def extract_embedded_url(url)
      uri = URI.parse(url)
      return nil if uri.query.blank?

      query_pairs(uri).each do |_key, value|
        candidate = value.to_s.strip
        return candidate if candidate =~ %r{\Ahttps?://}i
      end
      nil
    rescue StandardError
      nil
    end

    # Query-String als [[key, value], ...] mit dekodierten Werten.
    #
    # Ersetzt CGI.parse, das Ruby 4.0 entfernt hat. Auch nicht
    # URI.decode_www_form: das wirft bei einem Segment ohne "=" und verwirft
    # dann den ganzen Query-String samt der gueltigen Paare. CGI.parse war an
    # dieser Stelle tolerant, und genau darauf kommt es hier an - die
    # Redirect-Links, die wir auspacken wollen, sind selten sauber gebaut.
    def query_pairs(uri)
      return [] if uri.query.blank?

      uri.query.split(/[&;]/).filter_map do |pair|
        key, value = pair.split('=', 2)
        next if key.nil? || key.empty?

        [decode_component(key), decode_component(value)]
      end
    end

    def decode_component(value)
      URI.decode_www_form_component(value.to_s)
    rescue ArgumentError
      # Kaputtes Prozent-Encoding: unveraendert durchreichen statt den
      # kompletten Link zu verlieren.
      value.to_s
    end

    # Ist der Host ein bekannter Kurz-URL-Dienst?
    def shortener?(url)
      host = URI.parse(url).host.to_s.downcase.sub(/\Awww\./, '')
      return false if host.empty?

      SHORTENER_DOMAINS.any? { |d| host == d || host.end_with?(".#{d}") }
    rescue URI::Error
      false
    end

    # Findet HTML-Anchors, deren sichtbarer Text eine andere Domain zeigt
    # als das href-Ziel (klassische Link-Verschleierung).
    def find_anchor_mismatches(html)
      html.scan(ANCHOR_PATTERN).filter_map do |href, inner|
        shown = inner.gsub(/<[^>]+>/, ' ')[DOMAIN_IN_TEXT]
        next unless shown

        href_host = begin
          URI.parse(href).host.to_s.downcase.sub(/\Awww\./, '')
        rescue URI::Error
          nil
        end
        next if href_host.blank?

        shown_host = shown.downcase.sub(/\Awww\./, '').chomp('.')
        next if href_host == shown_host ||
                href_host.end_with?(".#{shown_host}") ||
                shown_host.end_with?(".#{href_host}")

        { :href => href.sub(/[.,;:!?]+\z/, ''), :shown => shown_host, :actual => href_host }
      end
    end

    def build_suspicion(url, reason, detail)
      label = case reason
              when :redirect
                I18n.t(:text_helpdesk_phishing_suspicion_redirect, :target => detail)
              when :shortener
                I18n.t(:text_helpdesk_phishing_suspicion_shortener)
              else
                I18n.t(:text_helpdesk_phishing_suspicion_anchor, :detail => detail)
              end
      { :url => url, :reason => reason, :detail => detail, :label => label }
    end

    # Ersetzt Treffer-URLs, markiert Verdachtsfaelle mit Warnbox und stellt
    # ein Warnbanner voran.
    def rewrite_part(part, hits, suspicions)
      body = decoded_body(part)
      return if body.blank?

      changed = false
      is_html = part.content_type.to_s =~ %r{text/html}i

      hits.each_value do |hit|
        replacement = replacement_text(hit, is_html)
        escaped_url = Regexp.escape(hit[:url])
        next unless body =~ /#{escaped_url}/

        body = body.gsub(/#{escaped_url}/, replacement)
        changed = true
      end

      suspicions.each_value do |suspicion|
        escaped_url = Regexp.escape(suspicion[:url])
        if is_html
          # Warnbox hinter den zugehoerigen Anchor setzen (nie in Attribute schreiben)
          anchor = /(<a\b[^>]*href\s*=\s*["']?#{escaped_url}["']?[^>]*>.*?<\/a>)/im
          if body =~ anchor
            box = suspicion_html_box(suspicion[:label])
            body = body.gsub(anchor) { "#{Regexp.last_match(1)}#{box}" }
            changed = true
          end
        elsif body =~ /#{escaped_url}/
          body = body.gsub(/#{escaped_url}/) { |u| "#{u} [⚠ #{suspicion[:label]}]" }
          changed = true
        end
      end

      return unless changed

      banner = if hits.any?
                 is_html ? html_banner : text_banner
               else
                 is_html ? html_suspicion_banner : text_suspicion_banner
               end
      body = banner + body

      # Body ist jetzt UTF-8 – Charset des Parts entsprechend setzen,
      # sonst interpretiert der Empfaenger die Bytes im alten Charset.
      part.body = nil
      part.charset = 'UTF-8'
      part.content_transfer_encoding = 'base64'
      part.body = Mail::Encodings::Base64.encode(body)
    end

    def replacement_text(hit, is_html)
      label = I18n.t(:text_helpdesk_phishing_link_removed, :source => hit[:source_label])
      is_html ? "<span style=\"color:#c00; font-weight:bold;\">[#{label}]</span>" : "[#{label}]"
    end

    def text_banner
      "!!! #{I18n.t(:text_helpdesk_phishing_warning_banner)} !!!\n\n"
    end

    def html_banner
      "<div style=\"background:#c00; color:#fff; padding:8px; font-weight:bold; margin-bottom:10px;\">" \
        "&#9888; #{I18n.t(:text_helpdesk_phishing_warning_banner)}</div>"
    end

    def text_suspicion_banner
      "!!! #{I18n.t(:text_helpdesk_phishing_suspicion_banner)} !!!\n\n"
    end

    def html_suspicion_banner
      "<div style=\"background:#fff3cd; color:#7a5c00; border:2px solid #e0a800; padding:8px; font-weight:bold; margin-bottom:10px;\">" \
        "&#9888; #{I18n.t(:text_helpdesk_phishing_suspicion_banner)}</div>"
    end

    def suspicion_html_box(label)
      "<span style=\"display:inline-block; background:#fff3cd; color:#7a5c00; border:1px solid #e0a800; " \
        "padding:2px 6px; margin:0 4px; font-weight:bold;\">&#9888; #{ERB::Util.html_escape(label)}</span>"
    end
  end
end
