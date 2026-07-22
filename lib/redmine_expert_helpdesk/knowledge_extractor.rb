# Extrahiert aus einem abgeschlossenen Ticket ein {Problem, Loesung}-Paar fuer die
# Wissensbasis. Nutzt den bestehenden AiClient (Chat) mit einem JSON-liefernden
# Prompt. Liefert nichts Verwertbares, wenn keine echte Loesung erkennbar ist.
module RedmineExpertHelpdesk
  class KnowledgeExtractor
    Result = Struct.new(:problem, :solution, :has_solution, :usage, keyword_init: true)

    DEFAULT_PROMPT = <<~PROMPT.freeze
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

    MAX_CHARS = 20_000

    def initialize(settings = nil)
      @settings = settings || Setting.plugin_redmine_expert_helpdesk
    end

    # Liefert ein Result oder nil (nicht konfiguriert / kein Inhalt).
    def extract(issue)
      text = ticket_text(issue)
      return nil if text.blank?

      client = RedmineExpertHelpdesk::AiClient.new(@settings)
      return nil unless client.configured?

      prompt = @settings['kb_extract_prompt'].presence || DEFAULT_PROMPT
      raw    = client.summarize(prompt, text)
      data   = parse_json(raw)
      return nil unless data

      Result.new(
        :problem      => data['problem'].to_s.strip,
        :solution     => data['solution'].to_s.strip,
        :has_solution => data['has_solution'] == true && data['solution'].to_s.strip.present?,
        :usage        => client.last_usage
      )
    end

    private

    # Beschreibung + alle Journal-Notizen (der Loesungsweg steht oft in internen
    # Notizen; die Wissensbasis ist projektintern). Eigene KI-Notizen ausschliessen.
    def ticket_text(issue)
      own = HelpdeskAiSummary.where(:issue_id => issue.id).pluck(:journal_id).compact.to_set
      parts = []
      parts << issue.description.to_s if issue.description.present?
      issue.journals.order(:created_on).each do |j|
        next if j.notes.blank? || own.include?(j.id)

        author = j.user ? j.user.name : '?'
        parts << "--- #{author} ---\n#{j.notes}"
      end
      text = parts.join("\n\n")
      text.length > MAX_CHARS ? text[0, MAX_CHARS] : text
    end

    # Tolerantes JSON-Parsing: evtl. Codeblock-Markierung entfernen, nur das
    # erste JSON-Objekt betrachten.
    def parse_json(raw)
      s = raw.to_s.strip
      s = s.sub(/\A```(?:json)?\s*/i, '').sub(/```\s*\z/, '')
      m = s.match(/\{.*\}/m)
      return nil unless m

      JSON.parse(m[0])
    rescue JSON::ParserError
      nil
    end
  end
end
