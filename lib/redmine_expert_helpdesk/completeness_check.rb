# Completeness check for the initial mail of a helpdesk ticket.
#
# Customers regularly open a ticket with "Drucker geht nicht" and nothing else.
# This class decides whether such a mail carries enough information for an agent
# to start working, so HelpdeskCompletenessJob can ask the customer for the rest
# before the SLA clock has burnt the first cycle.
#
# Two modes, both ending in the same Verdict:
# - heuristic: the rule set configured per project (length, attachments,
#   keywords). No external dependency, no cost, works with AI switched off.
# - ai: the model answers with JSON, parsed by parse_ai_verdict below.
#
# Reasons are returned as SYMBOLS, not sentences: the mail to the customer, the
# journal note and the tests each render them in their own locale. AI reasons are
# free text from the model and are passed through as strings.
#
# This class is pure (no DB writes, no mail, no HTTP) so the rule table is
# testable without a Redmine environment.
require 'json'

module RedmineExpertHelpdesk
  class CompletenessCheck
    # complete : true when the mail is good enough (no request is sent)
    # reasons  : symbols (heuristic) or strings (ai) naming what is missing
    # source   : 'heuristic' | 'ai' | 'error' — 'error' always means "complete",
    #            see the fail-closed rule in parse_ai_verdict.
    Verdict = Struct.new(:complete, :reasons, :source, :keyword_init => true) do
      def complete?
        complete ? true : false
      end

      def incomplete?
        !complete?
      end
    end

    MODES = %w[off heuristic ai].freeze

    # Bilder unter dieser Groesse zaehlen nicht als Screenshot/Foto. Signatur-Logos
    # und Tracking-Pixel haengen an fast jeder Mail und liegen typisch bei 1-10 KB;
    # ein echter Screenshot oder ein Handyfoto liegt deutlich darueber.
    DEFAULT_MIN_ATTACHMENT_KB = 15

    # Quoted history and signatures are not new information, so they must not
    # push a two-word mail over the length threshold. Covers Outlook (German and
    # English), Gmail/Thunderbird ("Am ... schrieb ...:"), plain "> " quoting and
    # the RFC 3676 signature delimiter.
    QUOTE_MARKERS = [
      /^\s*-{2,}\s*(urspr(ü|ue)ngliche nachricht|original message|weitergeleitete nachricht|forwarded message)\s*-{2,}/i,
      /^\s*_{5,}\s*$/,
      /^\s*-- \s*$/,
      /^\s*(von|from|gesendet|sent|betreff|subject|an|to)\s*:\s.*$\n^\s*(von|from|gesendet|sent|betreff|subject|an|to)\s*:\s/i,
      /^\s*(am|on)\s.{0,80}\s(schrieb|wrote)\s*:?\s*$/i
    ].freeze

    # Central default prompt for the AI mode. Deliberately asks for STRICT JSON
    # and for a conservative verdict: a false "incomplete" mails a customer who
    # did nothing wrong, which is worse than a missed check.
    DEFAULT_AI_PROMPT = <<~PROMPT.freeze
      Du bist ein Assistent im technischen Kundensupport (Helpdesk). Pruefe, ob die
      folgende Kundennachricht genug Informationen enthaelt, damit ein Bearbeiter mit
      der Bearbeitung beginnen kann.

      Ausreichend ist eine Nachricht in der Regel dann, wenn erkennbar ist:
      - worum es geht (betroffenes System, Anwendung, Geraet oder Dienst),
      - was genau passiert (Fehlermeldung, Symptom, beobachtetes Verhalten),
      - seit wann bzw. wann es auftritt oder wie es reproduziert werden kann.

      Bildmaterial hilft fast immer weiter, deshalb zusaetzlich:
      - Geht es um SOFTWARE (Anwendung, Web-Portal, Betriebssystem, Fehlerdialog,
        Meldung auf dem Bildschirm)? Dann sollte ein SCREENSHOT der Fehlermeldung
        bzw. des betroffenen Fensters vorliegen.
      - Geht es um HARDWARE (Geraet, Drucker, Kasse, Bildschirm, Kabel, Netzteil,
        Beschaedigung, Anzeige am Geraet)? Dann sollte ein FOTO des Geraets bzw.
        der Stelle vorliegen - moeglichst mit Typenschild, Seriennummer oder der
        Anzeige im Display.
      - Laesst sich nicht entscheiden, ob Software oder Hardware gemeint ist,
        fordere kein Bildmaterial an, sondern frage nach dem betroffenen System.

      Am Ende der Nachricht steht ein Abschnitt "Anhaenge dieser Mail:" mit den
      beigefuegten Dateien. Verlange NIEMALS etwas, das dort bereits aufgefuehrt
      ist: liegt ein Bild bei, ist die Bild-Anforderung erfuellt. Steht dort
      "keine", enthaelt die Mail keine verwertbaren Anhaenge. Winzige Bilder
      (Signatur-Logos, Tracking-Pixel) sind bereits herausgefiltert und tauchen
      dort nicht auf - du musst sie nicht selbst erkennen.

      Bewerte im Zweifel als ausreichend. Eine unnoetige Rueckfrage aergert Kunden,
      die alles Noetige geschrieben haben. Reine Hoeflichkeitsfloskeln, Signaturen
      und zitierte Verlaeufe zaehlen nicht als Information.

      Antworte AUSSCHLIESSLICH mit JSON in genau dieser Form, ohne Codeblock und
      ohne weiteren Text:
      {"complete": true|false, "missing": ["fehlende Angabe 1", "fehlende Angabe 2"]}

      Bei "complete": true muss "missing" ein leeres Array sein. Formuliere die
      Eintraege in "missing" als kurze, hoefliche deutsche Stichpunkte, die dem
      Kunden direkt als Rueckfrage vorgelegt werden koennen.
    PROMPT

    class << self
      # setting: a HelpdeskProjectSetting (or any object answering the same
      # info_request_* readers — the tests pass a Struct).
      def evaluate(text:, attachments: [], setting:)
        body = meaningful_text(text)
        reasons = []

        min_chars = setting.info_request_min_chars.to_i
        reasons << :too_short if min_chars.positive? && body.length < min_chars

        min_words = setting.info_request_min_words.to_i
        reasons << :too_few_words if min_words.positive? && word_count(body) < min_words

        if setting.info_request_require_attachment? &&
           relevant_attachments(attachments, setting).empty?
          reasons << :no_attachment
        end

        keywords = keyword_list(setting)
        if keywords.any? && keywords.none? { |k| body.downcase.include?(k) }
          reasons << :no_keyword
        end

        # A threshold of 0 or below would fire on a perfect mail, so treat it as 1.
        threshold = setting.info_request_threshold.to_i
        threshold = 1 unless threshold.positive?

        Verdict.new(
          :complete => reasons.size < threshold,
          :reasons => reasons,
          :source => 'heuristic'
        )
      end

      # Parses the model's answer. FAILS CLOSED: anything we cannot read counts as
      # complete, because a garbled response must never trigger a mail to a customer.
      def parse_ai_verdict(raw)
        json = extract_json(raw.to_s)
        return error_verdict('keine JSON-Antwort erhalten') if json.nil?

        data = JSON.parse(json)
        return error_verdict('unerwartete JSON-Struktur') unless data.is_a?(Hash)

        complete = data['complete']
        # Only a literal false (or "false") counts as incomplete; a missing or
        # non-boolean key is a malformed answer, not a verdict.
        return error_verdict('Feld "complete" fehlt oder ist kein Boolean') unless
          [true, false, 'true', 'false'].include?(complete)

        return Verdict.new(:complete => true, :reasons => [], :source => 'ai') if
          complete == true || complete == 'true'

        missing = Array(data['missing']).map { |m| m.to_s.strip }.reject(&:blank?)
        # "incomplete" without a single reason gives the customer nothing to answer.
        return error_verdict('unvollstaendig ohne Begruendung') if missing.empty?

        Verdict.new(:complete => false, :reasons => missing, :source => 'ai')
      rescue JSON::ParserError => e
        error_verdict("JSON nicht lesbar: #{e.message}")
      end

      # Strips quoted history and normalises whitespace, so quoted-printable line
      # noise and a forwarded thread cannot inflate the measured length.
      def meaningful_text(text)
        body = text.to_s
        QUOTE_MARKERS.each do |marker|
          if (match = body.match(marker))
            body = body[0...match.begin(0)]
          end
        end
        body = body.lines.reject { |line| line =~ /^\s*>/ }.join
        body.gsub(/\s+/, ' ').strip
      end

      # Anhaenge, die als Beweismaterial durchgehen. Die Groessenschwelle gilt NUR
      # fuer Bilder: sie existiert wegen Signatur-Logos und Tracking-Pixeln, die
      # sonst jede Mail "mit Screenshot" aussehen liessen. Ein 2-KB-Log oder ein
      # kleines PDF ist dagegen echtes Beweismaterial und bleibt drin.
      def relevant_attachments(attachments, setting = nil)
        min_bytes = min_attachment_kb(setting) * 1024

        Array(attachments).reject do |a|
          next false unless image?(a)
          next false unless min_bytes.positive?

          size = a.respond_to?(:filesize) ? a.filesize.to_i : 0
          # Groesse unbekannt (0/nil) => im Zweifel behalten, nicht verwerfen.
          size.positive? && size < min_bytes
        end
      end

      def min_attachment_kb(setting)
        return DEFAULT_MIN_ATTACHMENT_KB unless
          setting.respond_to?(:info_request_min_attachment_kb)

        value = setting.info_request_min_attachment_kb
        # nil => Default; 0 schaltet die Schwelle bewusst ab.
        value.nil? ? DEFAULT_MIN_ATTACHMENT_KB : value.to_i
      end

      def image?(attachment)
        type = attachment.respond_to?(:content_type) ? attachment.content_type.to_s : ''
        return true if type.downcase.start_with?('image/')
        return false if type.present?

        # Kein Content-Type gemeldet: ueber die Endung entscheiden.
        name = attachment.respond_to?(:filename) ? attachment.filename.to_s : ''
        name.downcase.end_with?('.png', '.jpg', '.jpeg', '.gif', '.bmp', '.webp', '.heic')
      end

      # Anhang-Inventar fuer den KI-Modus. Der Prompt fordert Screenshots/Fotos an,
      # kann aber ohne diese Liste nicht sehen, dass laengst eines beiliegt - er
      # wuerde dann etwas verlangen, das der Kunde bereits geschickt hat.
      # Name + Typ genuegen; die Bilddaten selbst gehen bewusst NICHT mit.
      def attachment_inventory(attachments, setting = nil)
        list = relevant_attachments(attachments, setting).filter_map do |a|
          name = a.respond_to?(:filename) ? a.filename.to_s : a.to_s
          next if name.blank?

          type = a.respond_to?(:content_type) ? a.content_type.to_s : ''
          type.present? ? "#{name} (#{type})" : name
        end

        "\n\nAnhaenge dieser Mail: #{list.any? ? list.join(', ') : 'keine'}"
      end

      def keyword_list(setting)
        setting.info_request_keywords.to_s
               .split(/[\r\n,]+/)
               .map { |k| k.strip.downcase }
               .reject(&:empty?)
      end

      private

      def word_count(body)
        body.split(/\s+/).count { |w| w =~ /[[:alnum:]]/ }
      end

      # Models like to wrap JSON in ```json fences or to prefix a sentence.
      # Take the outermost braces and let JSON.parse judge the rest.
      def extract_json(raw)
        first = raw.index('{')
        last  = raw.rindex('}')
        return nil if first.nil? || last.nil? || last < first

        raw[first..last]
      end

      def error_verdict(message)
        Rails.logger.warn("[helpdesk][info_request] KI-Antwort verworfen: #{message}")
        Verdict.new(:complete => true, :reasons => [], :source => 'error')
      rescue StandardError
        Verdict.new(:complete => true, :reasons => [], :source => 'error')
      end
    end
  end
end
