# Extrahiert aus einem abgeschlossenen Ticket ein {Problem, Loesung}-Paar fuer die
# Wissensbasis. Nutzt den bestehenden AiClient (Chat) mit einem JSON-liefernden
# Prompt. Liefert nichts Verwertbares, wenn keine echte Loesung erkennbar ist.
require 'strscan'

module RedmineExpertHelpdesk
  class KnowledgeExtractor
    Result = Struct.new(:problem, :solution, :has_solution, :usage, :detail, keyword_init: true)

    # How much of the ticket's concrete detail an entry keeps. 'general' is the
    # original behaviour; the finer levels keep what decides whether a past fix
    # applies at all (application, version, error code, path, system) - a
    # generalised "program does not start" matches every such ticket equally.
    DETAIL_LEVELS  = %w[general specific most_specific].freeze
    DEFAULT_DETAIL = 'general'.freeze

    PROMPT_HEAD = <<~PROMPT.freeze
      Du erhaeltst den vollstaendigen Verlauf eines ABGESCHLOSSENEN Support-Tickets
      (Kundenanfrage und Bearbeiter-Antworten). Der Verlauf beginnt mit der Betreffzeile
      ("Betreff: ..."); sie ist Teil der Kundenanfrage. Extrahiere daraus einen wiederverwendbaren
      Wissensbasis-Eintrag und antworte AUSSCHLIESSLICH mit einem JSON-Objekt mit genau
      diesen Feldern:
    PROMPT

    PROMPT_FIELDS = {
      'general' => <<~PROMPT,
        - "problem":  das urspruengliche Anliegen/Problem des Kunden, praegnant und
                      verallgemeinert (deutsch).
        - "solution": die tatsaechliche Loesung bzw. das Vorgehen, das zur Loesung fuehrte,
                      praegnant, verallgemeinert und ohne kundenspezifische Geheimnisse
                      (deutsch, gerne als kurze Schritte).
      PROMPT
      'specific' => <<~PROMPT,
        - "problem":  das urspruengliche Anliegen/Problem des Kunden, praegnant (deutsch).
                      Behalte die konkreten Merkmale bei: Name der Anwendung bzw. des
                      Produkts/Geraets, Version, Fehlercode und Fehlermeldung (wortgetreu),
                      betroffene Komponente oder Funktion.
        - "solution": die tatsaechliche Loesung bzw. das Vorgehen, das zur Loesung fuehrte
                      (deutsch, gerne als kurze Schritte). Nenne die beteiligten Anwendungen,
                      Versionen, Einstellungen und Menuepfade beim Namen.
      PROMPT
      'most_specific' => <<~PROMPT
        - "problem":  das urspruengliche Anliegen/Problem des Kunden (deutsch). Verallgemeinere
                      NICHT: Behalte Name der Anwendung bzw. des Produkts/Geraets, Version,
                      Fehlercode und Fehlermeldung (wortgetreu), Datei- und Registry-Pfade,
                      Server-, Host- und Freigabenamen sowie betroffene Komponenten bei.
        - "solution": die tatsaechliche Loesung bzw. das Vorgehen, das zur Loesung fuehrte,
                      als Schritte in der tatsaechlichen Reihenfolge (deutsch). Nenne Pfade,
                      Systeme, Konfigurationswerte, Befehle und Menuepfade exakt so, wie sie im
                      Verlauf stehen - gerade diese Details entscheiden, ob die Loesung auf
                      einen neuen Fall passt.
      PROMPT
    }.freeze

    PROMPT_TAIL = <<~PROMPT.freeze
        - "has_solution": true nur, wenn im Verlauf eine echte, nachvollziehbare Loesung
                      erkennbar ist; sonst false.

      Erfinde nichts. Wenn keine Loesung erkennbar ist, setze has_solution=false und
      solution auf einen leeren String. Gib nur das JSON aus, ohne Codeblock-Markierung.
    PROMPT

    # Sent at every level: the finer levels are about technical detail, not about
    # who the customer is or how to log in as them. An instruction to the model,
    # not a filter - the entry is still reviewable in the knowledge base tab.
    PROMPT_PRIVACY = <<~PROMPT.freeze
      Uebernimm niemals Passwoerter, Zugangsdaten, Tokens oder Lizenzschluessel, und keine
      personenbezogenen Daten (Namen, E-Mail-Adressen, Telefonnummern) des Kunden.
    PROMPT

    # Paths are what the finer levels keep, and a Windows path is backslashes.
    PROMPT_ESCAPING = <<~PROMPT.freeze
      Achte auf gueltiges JSON: Jeder Backslash in einem Wert wird verdoppelt, z. B. wird der
      Pfad \\\\server\\freigabe als "\\\\\\\\server\\\\freigabe" geschrieben.
    PROMPT

    def self.prompt_for(level)
      level = DEFAULT_DETAIL unless DETAIL_LEVELS.include?(level.to_s)
      fields = PROMPT_FIELDS.fetch(level.to_s).gsub(/^/, '  ')
      escaping = level.to_s == 'general' ? '' : "\n#{PROMPT_ESCAPING}"
      (PROMPT_HEAD + fields + PROMPT_TAIL + "\n" + PROMPT_PRIVACY + escaping).freeze
    end

    DEFAULT_PROMPT = prompt_for(DEFAULT_DETAIL)

    # Defaults shipped before DEFAULT_PROMPT; init.rb seeded whichever was current
    # at install time, so these copies sit in existing installs' settings too.
    # Before 0.7.1 (#18) the prompt did not mention the subject line; up to 0.20.3
    # it had no privacy sentence.
    LEGACY_DEFAULT_PROMPTS = [<<~PROMPT, <<~PROMPT].freeze
      Du erhaeltst den vollstaendigen Verlauf eines ABGESCHLOSSENEN Support-Tickets
      (Kundenanfrage und Bearbeiter-Antworten). Extrahiere daraus einen wiederverwendbaren
      Wissensbasis-Eintrag und antworte AUSSCHLIESSLICH mit einem JSON-Objekt mit genau
      diesen Feldern:
        - "problem":  das urspruengliche Anliegen/Problem des Kunden, praegnant und
                      verallgemeinert (deutsch).
        - "solution": die tatsaechliche Loesung bzw. das Vorgehen, das zur Loesung fuehrte,
                      praegnant, verallgemeinert und ohne kundenspezifische Geheimnisse
                      (deutsch, gerne als kurze Schritte).
        - "has_solution": true nur, wenn im Verlauf eine echte, nachvollziehbare Loesung
                      erkennbar ist; sonst false.

      Erfinde nichts. Wenn keine Loesung erkennbar ist, setze has_solution=false und
      solution auf einen leeren String. Gib nur das JSON aus, ohne Codeblock-Markierung.
    PROMPT
      Du erhaeltst den vollstaendigen Verlauf eines ABGESCHLOSSENEN Support-Tickets
      (Kundenanfrage und Bearbeiter-Antworten). Der Verlauf beginnt mit der Betreffzeile
      ("Betreff: ..."); sie ist Teil der Kundenanfrage. Extrahiere daraus einen wiederverwendbaren
      Wissensbasis-Eintrag und antworte AUSSCHLIESSLICH mit einem JSON-Objekt mit genau
      diesen Feldern:
        - "problem":  das urspruengliche Anliegen/Problem des Kunden, praegnant und
                      verallgemeinert (deutsch).
        - "solution": die tatsaechliche Loesung bzw. das Vorgehen, das zur Loesung fuehrte,
                      praegnant, verallgemeinert und ohne kundenspezifische Geheimnisse
                      (deutsch, gerne als kurze Schritte).
        - "has_solution": true nur, wenn im Verlauf eine echte, nachvollziehbare Loesung
                      erkennbar ist; sonst false.

      Erfinde nichts. Wenn keine Loesung erkennbar ist, setze has_solution=false und
      solution auf einen leeren String. Gib nur das JSON aus, ohne Codeblock-Markierung.
    PROMPT

    # A stored central prompt only counts as the admin's own when it differs from
    # every built-in and every formerly shipped default. Otherwise the copy init.rb
    # seeded would pin every existing install to it, whatever level is selected.
    def self.custom_prompt?(text)
      normalized = normalize(text)
      return false if normalized.empty?

      builtin = DETAIL_LEVELS.map { |level| prompt_for(level) } + LEGACY_DEFAULT_PROMPTS
      builtin.none? { |prompt| normalize(prompt) == normalized }
    end

    def self.normalize(text)
      text.to_s.gsub(/\s+/, ' ').strip
    end
    private_class_method :normalize

    # Central level; read with a fallback, since a key added to init.rb's
    # :default hash reads nil until the settings form is saved again.
    def self.central_detail(settings)
      level = (settings || {})['kb_extract_detail'].to_s
      DETAIL_LEVELS.include?(level) ? level : DEFAULT_DETAIL
    end

    # Central prompt for a level: the admin's own text, else the built-in one.
    def self.central_prompt(settings, level)
      own = (settings || {})['kb_extract_prompt'].to_s
      custom_prompt?(own) ? with_privacy(own.strip) : prompt_for(level)
    end

    # The privacy instruction survives own prompts (central or project override):
    # appended unless the text already carries it.
    def self.with_privacy(prompt)
      return prompt if normalize(prompt).include?(normalize(PROMPT_PRIVACY))

      "#{prompt.to_s.rstrip}\n\n#{PROMPT_PRIVACY}"
    end

    MAX_CHARS = 20_000

    def initialize(settings = nil)
      @settings = settings || Setting.plugin_redmine_expert_helpdesk
    end

    # Subject + description + journal notes, with the plugin's own AI notes and
    # AI-drafted replies removed (otherwise the model ends up learning from its
    # own output on the next close).
    #
    # include_private is the policy switch. The knowledge base wants internal
    # notes - that is where the fix is written down, and the entry never leaves
    # the project. The answer drafter must not have them: its output is one
    # click away from a customer's inbox. One builder, two policies.
    def self.ticket_text(issue, max_chars: MAX_CHARS, include_private: true)
      skip = HelpdeskAiSummary.where(:issue_id => issue.id).pluck(:journal_id).compact.to_set
      skip.merge(ai_drafted_journal_ids(issue))
      # Saved drafts that were never mailed - the second half of the same rule.
      skip.merge(HelpdeskAiDraftedJournal.journal_ids_for(issue.id))

      parts = []
      # The subject often carries the device and the error that the body only
      # refers to; without it the entry embeds "printer broken" as the problem.
      subject = issue.subject.to_s.strip
      parts << "Betreff: #{subject}" if subject.present?
      parts << issue.description.to_s if issue.description.present?
      issue.journals.order(:created_on).each do |j|
        next if j.notes.blank? || skip.include?(j.id)
        next if !include_private && j.private_notes?

        author = j.user ? j.user.name : '?'
        parts << "--- #{author} ---\n#{j.notes}"
      end
      text = parts.join("\n\n")
      text.length > max_chars ? text[0, max_chars] : text
    end

    # Journals of replies whose body came from an AI draft. Guarded: the column
    # arrives with migration 054, and this runs on every close.
    def self.ai_drafted_journal_ids(issue)
      return [] unless HelpdeskMessage.column_names.include?('ai_drafted')

      HelpdeskMessage.where(:issue_id => issue.id, :ai_drafted => true).pluck(:journal_id).compact
    rescue StandardError
      []
    end
    private_class_method :ai_drafted_journal_ids

    # Liefert ein Result oder nil (nicht konfiguriert / kein Inhalt).
    def extract(issue)
      text = ticket_text(issue)
      return nil if text.blank?

      client = RedmineExpertHelpdesk::AiClient.new(@settings)
      return nil unless client.configured?

      prompt, detail = prompt_and_detail(issue)
      raw    = client.summarize(prompt, text,
                                :log_context => { :request_type => 'kb_extract',
                                                  :project_id => issue.project_id, :issue_id => issue.id })
      data   = parse_json(raw, text)
      return nil unless data

      Result.new(
        :problem      => data['problem'].to_s.strip,
        :solution     => data['solution'].to_s.strip,
        :has_solution => data['has_solution'] == true && data['solution'].to_s.strip.present?,
        :usage        => client.last_usage,
        :detail       => detail
      )
    end

    private

    # The project decides (level, own prompt, mode); the extractor's settings
    # are the central side of that combination.
    def prompt_and_detail(issue)
      ps = issue.project && HelpdeskProjectSetting.for_project(issue.project)
      return [self.class.central_prompt(@settings, self.class.central_detail(@settings)),
              self.class.central_detail(@settings)] unless ps

      [ps.effective_kb_extract_prompt(@settings), ps.effective_kb_extract_detail(@settings)]
    end

    # Beschreibung + alle Journal-Notizen (der Loesungsweg steht oft in internen
    # Notizen; die Wissensbasis ist projektintern).
    def ticket_text(issue)
      self.class.ticket_text(issue, :max_chars => MAX_CHARS, :include_private => true)
    end

    # Tolerantes JSON-Parsing: evtl. Codeblock-Markierung entfernen, nur das
    # erste JSON-Objekt betrachten.
    def parse_json(raw, source = nil)
      s = raw.to_s.strip
      s = s.sub(/\A```(?:json)?\s*/i, '').sub(/```\s*\z/, '')
      m = s.match(/\{.*\}/m)
      return nil unless m

      json = repair_paths(m[0], source)
      begin
        JSON.parse(json)
      rescue JSON::ParserError
        # A lone backslash outside a recognisable path is no JSON escape either;
        # json >= 2.10 rejects it, and with it the whole entry.
        JSON.parse(json.gsub(ESCAPE_TOKEN) { |esc| esc.length == 1 ? '\\\\' : esc })
      end
    rescue JSON::ParserError => e
      Rails.logger.warn("[helpdesk][kb] Extraction answer is not valid JSON (#{raw.to_s.length} chars): #{e.message[0, 120]}")
      nil
    end

    # Models copy Windows paths verbatim ("C:\new\test", "\\SRV01\WINDVSW1").
    # That is either invalid JSON (\W - measured: 5 of 16 'most_specific' answers
    # for a UNC-path ticket) or, worse, valid JSON with the wrong meaning (\n, \t,
    # \b, \f), so it has to be repaired *before* parsing. Only path tokens are
    # touched - solution text is full of real \n line breaks.
    # source: the ticket text the answer was extracted from (see path_segment?).
    def repair_paths(json, source = nil)
      # With the ticket text at hand even an escape that reads like a line break
      # ("C:\Temp\nPruefen\test") stays in the token: path_segment? decides
      # whether the ticket has that segment. Without it, line breaks end a path.
      pattern = source ? PATH_TOKEN_WITH_BREAKS : PATH_TOKEN
      json.gsub(pattern) { |token| repair_path_token(token, source) }
    end

    # Per separator, not per token: models mix spellings within one path
    # ("\\SRV\\Share\new"). Valid escapes (\\ \" \/ \uXXXX) stay, every other
    # backslash is literal and gets doubled.
    def repair_path_token(token, source = nil)
      out = +''
      # A two-backslash UNC prefix is short either way: escaped it reads four.
      # "\\SRV\\Share" (separators escaped, only the prefix short) is the model's
      # usual spelling - 11 of 16 measured answers.
      if token.match?(/\A\\\\(?!\\)/)
        out << '\\\\\\\\'
        token = token[2..]
      end
      scanner = StringScanner.new(token)
      until scanner.eos?
        if (esc = scanner.scan(VALID_PATH_ESCAPE))
          out << esc
        elsif scanner.check(AMBIGUOUS_ESCAPE) && !path_segment?(scanner.rest, source)
          # A real \n (\t ...) followed by prose: the path ended before it.
          return out << scanner.rest
        elsif scanner.scan(/\\/)
          out << '\\\\'
        else
          out << scanner.getch
        end
      end
      out
    end

    # "C:\Temp\npruefen" is a path segment "\npruefen" or "C:\Temp" plus a line
    # break - the text alone cannot tell. The finer levels copy paths verbatim
    # from the ticket, so the ticket decides: a segment it contains is a path.
    # Without a source (or not found in it) it is the escape it spells.
    def path_segment?(rest, source)
      return true if source.nil?

      segment = rest[/\A\\[^\s"\\]+/].to_s
      source.downcase.include?(segment.downcase)
    end

    VALID_PATH_ESCAPE = %r{\\\\|\\["/]|\\u\h{4}}.freeze
    # A JSON control escape that could also start a path segment ("\new",
    # "\Temp\tTab" - tab or folder "tTab"?). Without ticket text, line breaks
    # followed by a list marker never reach a token (PATH_TOKEN stops before them).
    AMBIGUOUS_ESCAPE  = /\\[nrtbf]/.freeze

    # \n / \r that reads as a line break: followed by an uppercase letter, digit,
    # list marker, whitespace, quote or the end. JSON escapes are lowercase, so a
    # segment like "\new" is not taken for one.
    LINE_BREAK = /\\[nr](?=[[:upper:][:digit:]\-*•\s"]|\z)/.freeze
    # Drive letter or UNC start in the raw JSON text, then escaped pairs, single
    # backslashes that are no line break, and non-space characters. A space only
    # continues the token when up to three words later the path goes on
    # ("C:\Program Files (x86)\new"), so prose after a path is not swallowed.
    # Starts: drive letter, UNC, registry hive (HKEY_LOCAL_MACHINE, HKLM ...) and
    # environment variable (%APPDATA%) - the path kinds 'most_specific' keeps.
    PATH_START = %r{(?<![\\\w])(?:[A-Za-z]:\\|\\\\|(?i:HKEY_[A-Z_]+|HK(?:LM|CU|CR|U|CC))\\|%[A-Za-z_][\w()]*%\\)}.freeze
    PATH_TOKEN = %r{#{PATH_START}
                    (?:\\\\|(?!#{LINE_BREAK})\\|[^\s"\\]|
                       [ ](?=(?:[^\s"\\]+[ ]){0,2}[^\s"\\]+(?!#{LINE_BREAK})\\))*}x.freeze
    PATH_TOKEN_WITH_BREAKS = %r{#{PATH_START}
                                (?:\\\\|\\|[^\s"\\]|
                                   [ ](?=(?:[^\s"\\]+[ ]){0,2}[^\s"\\]+\\))*}x.freeze

    # A valid JSON escape (\" \\ \/ \b \f \n \r \t \uXXXX) as one token, else a
    # lone backslash. Valid pairs must be consumed whole: in "\\SRV" a lookahead
    # would skip the first backslash and then double the second.
    ESCAPE_TOKEN = /\\(?:["\\\/bfnrt]|u\h{4})|\\/.freeze
  end
end
