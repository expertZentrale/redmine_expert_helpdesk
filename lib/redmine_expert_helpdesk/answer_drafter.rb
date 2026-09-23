# Customer-facing answer draft for a ticket ("KI-Antwortvorschlag").
#
# Every other AI feature in this plugin writes for the agent: the summary
# condenses the customer's mail, the completeness check judges it, the knowledge
# base stores "PSU getauscht, Firmware 2.14 geflasht". This one writes for the
# customer, and the text it produces is appended straight into the note field -
# which is the body of the outgoing mail. That single fact drives the design:
#
# * The input is narrower than the knowledge extractor's. No private notes, no
#   attachments. The extractor may read internal notes because its output never
#   leaves the project; here the output is one click from a customer's inbox.
# * Without a knowledge-base hit there is no draft. An ungrounded German reply
#   is exactly the artefact that invents a repair date - refusing is the feature.
#   The only exception is the 'ask' variant, which proposes nothing and merely
#   asks for the missing facts.
# * The knowledge-base block carries no ticket numbers. A foreign ticket number
#   in a customer mail discloses the existence, and by inference the content, of
#   another customer's ticket.
# * Nothing here is persisted. See the comment on HelpdeskAiRequest: the
#   *rejected* draft is the text you least want to keep.
#
# Structured like KnowledgeExtractor - a plain object, no ActiveJob - so the
# prompt assembly is unit-testable without a database, HTTP or a vector store.
module RedmineExpertHelpdesk
  class AnswerDrafter
    Result = Struct.new(:content, :omitted, :sources, :truncated, keyword_init: true) do
      def truncated?
        !!truncated
      end
    end

    MAX_CHARS = 12_000

    # Stricter than the summary's kb_min_score by default: a weak hit in a
    # private summary is noise, a weak hit in a customer mail is a false
    # promise. Only the fallback - the effective value comes from
    # HelpdeskProjectSetting#effective_ai_answer_min_score (project, then
    # central, then this).
    DRAFT_MIN_SCORE = 0.65

    # The model emits this when the supplied cases do not actually fit. The score
    # threshold cannot catch a hit that is numerically close but about something
    # else; this can.
    NO_DRAFT_TOKEN = 'KEIN_ENTWURF'.freeze

    # Embedding is a small, fast call - it must not be allowed to spend the whole
    # request budget before the chat call has even started.
    EMBED_TIMEOUT      = 10
    STORE_OPEN_TIMEOUT = 5
    STORE_READ_TIMEOUT = 8
    # The reranker is the same shape of call, and the same argument applies: an
    # agent is waiting, so it gets a tighter budget here than the jobs give it.
    # A reranker that times out costs ordering, not the draft - retrieval falls
    # back to the vector hits.
    RERANK_TIMEOUT     = 5

    DEFAULT_PROMPT = <<~PROMPT.freeze
      Du bist ein erfahrener Mitarbeiter im technischen Kundensupport und
      formulierst die ANTWORT AN DEN KUNDEN zu genau diesem Ticket. Schreibe auf
      Deutsch.

      Zielgruppe ist der Kunde, nicht der Bearbeiter. Schreibe so, dass eine
      Person ohne IT-Kenntnisse der Antwort folgen kann.

      Aufbau:
      - Greife das Anliegen in ein bis zwei Saetzen auf, damit der Kunde sieht,
        dass es verstanden wurde.
      - Nenne danach konkret, was der Kunde tun soll. Ab drei Schritten als
        nummerierte Liste; jeder Schritt ist genau eine ueberpruefbare Handlung.
      - Schliesse mit einem kurzen Angebot zur Rueckmeldung, falls es damit nicht
        behoben ist.

      Erfinde nichts:
      - Verwende ausschliesslich Informationen aus dem Ticketverlauf und aus den
        unten genannten Faellen der Wissensbasis.
      - Nenne keine Versionsnummern, Pfade, Preise, Termine, Fristen,
        Bearbeitungszeiten oder Zustaendigkeiten, die nicht im Ticket stehen.
      - Sage nichts zu: Reparatur, Austausch, Gutschrift, Kulanz oder Garantie,
        solange es nicht bereits im Ticketverlauf zugesagt wurde.
      - Ist die Ursache unklar oder fehlen Angaben, frage genau diese Angaben ab,
        statt eine Loesung zu vermuten. Eine ehrliche Rueckfrage ist besser als
        ein geratener Loesungsweg.

      Nichts Internes nach aussen:
      - Keine Ticketnummern und keine Verweise auf andere Kunden, andere Tickets
        oder auf die Wissensbasis. Formulierungen wie "wie in einem frueheren
        Fall" sind verboten.
      - Keine internen Notizen, Werkzeuge, System- oder Servernamen, keine
        Zugangsdaten, keine Kollegennamen, keine Einkaufspreise, keine internen
        Ablaeufe.
      - Erwaehne nicht, dass dieser Text von einer KI erzeugt wurde, und schreibe
        nicht ueber dich selbst.

      Form:
      - Hoeflich, Sie-Anrede, sachlich, kurze Saetze, keine Floskelketten.
      - Reiner Text, Leerzeilen als Absatztrennung. Keine Ueberschriften, keine
        Tabellen, keine Code-Bloecke, keine Emojis.
      - Gib ausschliesslich den Antworttext aus: keine Einleitung, keine
        Erklaerung, keine Anfuehrungszeichen um den Text, keine
        Codeblock-Markierung.
      - Antworte auf Deutsch.
    PROMPT

    # key => [needs knowledge-base grounding?, extra instruction]
    #
    # The suffix is concatenated into the system prompt, so this whitelist is the
    # injection boundary - never pass a variant through from params unchecked.
    VARIANTS = {
      'standard' => [true, ''],
      'steps'    => [true, 'Variante: Schritt-fuer-Schritt-Anleitung. Gib die Loesung als ' \
                           'nummerierte Liste kleiner, einzeln ausfuehrbarer Schritte aus und ' \
                           'nenne jeweils, woran der Kunde erkennt, dass der Schritt geklappt hat.'],
      'short'    => [true, 'Variante: Kurzantwort. Hoechstens fuenf Saetze, keine nummerierte ' \
                           'Liste, nur der wichtigste naechste Schritt.'],
      # Needs no grounding: it proposes nothing. This is what makes the feature
      # usable on day one against an empty knowledge base without softening the
      # refusal rule for the variants that do propose a fix.
      'ask'      => [false, 'Variante: Rueckfrage. Die vorliegenden Angaben reichen fuer eine ' \
                            'Loesung nicht aus. Frage hoeflich genau die fehlenden Angaben ab ' \
                            '(kurze Liste) und begruende knapp, wofuer sie gebraucht werden. ' \
                            'Schlage ausdruecklich KEINE Loesung und keine Ursache vor.']
    }.freeze

    DEFAULT_VARIANT = 'standard'.freeze

    class << self
      # Everything that must be true before the button is even offered. Cheap:
      # hash reads plus one row that the edit view has loaded anyway.
      def available_for?(project, contact)
        return false if contact.nil?
        return false unless AiFeatures.answer_draft_enabled?
        return false unless HelpdeskProjectSetting.for_project(project).ai_answer_enabled?

        AiClient.new.configured?
      end

      # Menu entries for the toolbar, or [] when the feature is unavailable -
      # keeps the gate out of the view and out of hooks.rb.
      def menu_variants(project, contact)
        return [] unless available_for?(project, contact)

        VARIANTS.keys.map do |key|
          { :key => key, :label => I18n.t(:"label_helpdesk_ai_answer_variant_#{key}") }
        end
      end

      def variant_key(raw)
        key = raw.to_s.strip
        VARIANTS.key?(key) ? key : DEFAULT_VARIANT
      end

      # Presentation, not a resource: an unknown variant falls back rather than
      # failing the request (an unknown *source* stays a hard error).
      def needs_grounding?(variant)
        VARIANTS.fetch(variant_key(variant)).first
      end
    end

    # Raised when retrieval found nothing usable, or the model said so itself.
    # Separate from AiError because it is a normal outcome, not a failure.
    #
    # Carries the best score that was rejected, so the agent can be told whether
    # the bar was missed narrowly or nothing came close - the difference between
    # "lower the threshold" and "this case is genuinely new".
    class NoGroundingError < StandardError
      attr_reader :best_score, :threshold

      def initialize(message = nil, best_score: nil, threshold: nil)
        super(message)
        @best_score = best_score
        @threshold  = threshold
      end
    end

    # The knowledge base is switched off or not configured at all. Deliberately
    # distinct from NoGroundingError: "we looked and found nothing" sends the
    # agent to the answer templates, "there is nothing to look in" sends an
    # administrator to the settings. Reporting the second as the first is how
    # somebody spends an afternoon searching for an entry they know exists.
    class KbUnavailableError < StandardError; end

    def initialize(settings = nil)
      @settings = settings || Setting.plugin_redmine_expert_helpdesk
    end

    # Returns a Result, or raises NoGroundingError / AiClient::AiError.
    def draft(issue, contact:, variant: DEFAULT_VARIANT, user: User.current)
      variant = self.class.variant_key(variant)
      text    = ticket_text(issue)
      raise NoGroundingError if text.blank?

      diag = {}
      hits = self.class.needs_grounding?(variant) ? grounding_hits(issue, text, user, diag) : []
      if self.class.needs_grounding?(variant) && hits.empty?
        raise NoGroundingError.new(:best_score => diag[:best_score], :threshold => diag[:threshold])
      end

      client  = chat_client
      content = client.summarize(
        system_prompt(issue, contact, variant, hits), text, [],
        :log_context => { :request_type => 'answer_draft', :project_id => issue.project_id,
                          :issue_id => issue.id, :user_id => user&.id }
      )
      content = sanitize(content)
      raise NoGroundingError if content.delete("\n").strip == NO_DRAFT_TOKEN || content.include?(NO_DRAFT_TOKEN)

      log(issue, variant, hits, content)
      Result.new(:content => content, :omitted => 0, :sources => sources_for(hits),
                 :truncated => client.last_finish_reason == 'length')
    end

    private

    def timeout
      v = @settings['ai_answer_timeout'].to_i
      v.positive? ? v.clamp(5, 45) : 20
    end

    def max_tokens
      v = @settings['ai_answer_max_tokens'].to_i
      v.positive? ? v : 900
    end

    # AiClient reads its limits from the settings hash it is constructed with, so
    # a merged copy gives this feature its own budget without touching the client
    # or any of the four other call sites. A customer answer needs more room than
    # a bullet summary; a web request needs a shorter leash than a background job.
    def chat_client
      AiClient.new(@settings.merge('ai_max_output_tokens' => max_tokens.to_s,
                                   'ai_timeout' => timeout.to_s))
    end

    # Timeouts werden hier - wie ueberall in dieser Klasse - ueber eine Kopie
    # des Einstellungs-Hashes gesetzt: der Client liest seine Grenzen aus dem
    # Hash, mit dem er gebaut wurde, also ist keine andere Aufrufstelle betroffen.
    def embed_client
      AiClient.new(@settings.merge('ai_timeout'        => [EMBED_TIMEOUT, timeout].min.to_s,
                                   'kb_rerank_timeout' => [RERANK_TIMEOUT, timeout].min.to_s))
    end

    def store_for_draft
      store = KnowledgeStore.for(@settings)
      store.open_timeout = STORE_OPEN_TIMEOUT if store.respond_to?(:open_timeout=)
      store.read_timeout = STORE_READ_TIMEOUT if store.respond_to?(:read_timeout=)
      store.connect_timeout = STORE_OPEN_TIMEOUT if store.respond_to?(:connect_timeout=)
      store
    end

    def grounding_hits(issue, text, user, diagnostics = nil)
      client = embed_client
      store  = store_for_draft
      raise KbUnavailableError unless AiFeatures.kb_enabled? && store.configured? && client.embed_configured?

      KnowledgeRetrieval.search(
        issue, @settings, client, text,
        :request_type => 'kb_retrieve',
        :min_score => min_score_for(issue),
        :store => store,
        :user_id => user&.id,
        :raise_on_error => true,
        :diagnostics => diagnostics
      )
    end

    # Project value, else central, else the shipped default. Clamped to 0..1 so
    # a typo in the settings form cannot switch the grounding requirement off.
    def min_score_for(issue)
      value =
        if issue.project
          HelpdeskProjectSetting.for_project(issue.project).effective_ai_answer_min_score
        else
          HelpdeskProjectSetting.parse_ai_answer_min_score(@settings['ai_answer_min_score'])
        end
      (value || DRAFT_MIN_SCORE).to_f.clamp(0.0, 1.0)
    rescue ArgumentError, TypeError
      DRAFT_MIN_SCORE
    end

    # Public conversation only. See the class comment: no private notes, and no
    # switch to re-enable them - a toggle whose failure mode is a customer
    # reading an internal note is not a toggle worth having.
    def ticket_text(issue)
      KnowledgeExtractor.ticket_text(issue, :max_chars => max_input_chars, :include_private => false)
    end

    def max_input_chars
      v = @settings['ai_max_input_chars'].to_i
      v.positive? ? v : MAX_CHARS
    end

    # Nil-tolerant: the unit tests build a drafter over a bare settings hash and
    # never touch the database.
    def project_prompt(issue)
      return nil unless issue.project

      HelpdeskProjectSetting.for_project(issue.project).effective_ai_answer_prompt
    rescue StandardError
      nil
    end

    def system_prompt(issue, contact, variant, hits)
      # Same shape as the summary job: the project setting already folds the
      # central prompt in (inherit/extend/override), and an empty setting still
      # yields the shipped default.
      base = project_prompt(issue).presence || @settings['ai_answer_prompt'].presence || DEFAULT_PROMPT

      context = { :issue => issue, :contact => contact, :user => User.current }
      parts   = [TemplateRenderer.render(base, context)]
      parts << VARIANTS.fetch(variant).last.presence
      parts << frame_block(issue, context)
      parts << kb_block(hits)
      parts.compact.join("\n\n")
    end

    # What the reply controller will wrap around this text on send. Rendering the
    # actual header and footer beats describing them: it costs a few dozen tokens
    # and removes every doubt about whether the footer already says
    # "Mit freundlichen Gruessen" - otherwise the customer gets two greetings.
    def frame_block(issue, context)
      mailbox = mailbox_for(issue)
      header  = mailbox ? TemplateRenderer.render(mailbox.reply_header.to_s, context).to_s.strip : ''
      footer  = mailbox ? TemplateRenderer.render(mailbox.effective_footer_template.to_s, context).to_s.strip : ''

      lines = ['---', 'Rahmen der Mail beim Versand:']
      lines << if header.present?
                 "Dieser Text wird automatisch VORANGESTELLT:\n\"\"\"\n#{clip(header)}\n\"\"\"\n" \
                   'Wiederhole ihn nicht und beginne nicht mit einer eigenen Anrede.'
               else
                 'Es wird kein Kopftext ergaenzt: Beginne mit einer passenden Anrede an den Kunden.'
               end
      lines << if footer.present?
                 "Dieser Text wird automatisch ANGEHAENGT:\n\"\"\"\n#{clip(footer)}\n\"\"\"\n" \
                   'Wiederhole ihn nicht und ende mit dem letzten inhaltlichen Satz - ohne eigene ' \
                   'Grussformel, ohne Namen, ohne Signatur.'
               else
                 'Es wird kein Fusstext ergaenzt: Schliesse mit einer kurzen Grussformel, aber ' \
                   'ohne Namen und ohne Signatur.'
               end
      lines.join("\n")
    end

    def mailbox_for(issue)
      info    = HelpdeskTicketInfo.for_issue(issue)
      mailbox = info&.helpdesk_mailbox&.enabled? ? info.helpdesk_mailbox : nil
      mailbox || issue.project.helpdesk_mailboxes.enabled.first
    rescue StandardError
      nil
    end

    def clip(text, limit = 500)
      text.length > limit ? "#{text[0, limit]}..." : text
    end

    def kb_block(hits)
      return nil if hits.empty?

      "---\n" \
        "Aehnliche frueher geloeste Faelle aus der Wissensbasis. NUR INTERN als fachliche\n" \
        "Grundlage - erwaehne sie im Antworttext mit keinem Wort:\n" \
        "#{KnowledgeRetrieval.format_hits(hits, :with_issue_ids => false)}\n\n" \
        'Passt einer der Faelle zum Anliegen, formuliere dessen Loesung als Anleitung fuer den ' \
        'Kunden um. Passt keiner davon wirklich, antworte ausschliesslich mit dem Wort ' \
        "#{NO_DRAFT_TOKEN} und sonst nichts."
    end

    # Models like to wrap the answer, announce it, or invent a subject line that
    # would then sit inside the mail body under the real subject.
    def sanitize(raw)
      s = raw.to_s.strip
      s = s.sub(/\A```[a-z]*\s*/i, '').sub(/```\s*\z/, '').strip
      s = s.sub(/\A(hier ist|hier der|gerne|anbei)[^\n]{0,60}:\s*\n+/i, '')
      s = s.sub(/\ABetreff:[^\n]*\n+/i, '')
      s.strip
    end

    def sources_for(hits)
      hits.map do |h|
        p = h[:payload] || {}
        { :issue_id => p['issue_id'].to_i, :score => h[:score].to_f }
      end
    end

    # Lengths and decisions only - never the prompt, the knowledge-base block or
    # the output. Rails logs go to stdout and the cluster log store, whose
    # retention has nothing to do with the ticket's.
    def log(issue, variant, hits, content)
      top = hits.map { |h| h[:score].to_f }.max
      AiLogger.debug("draft issue=##{issue.id} variant=#{variant} kb_hits=#{hits.size} " \
                     "top_score=#{top ? top.round(2) : '-'} chars=#{content.to_s.length}")
    end
  end
end
