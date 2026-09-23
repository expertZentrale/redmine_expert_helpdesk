# KI-Client fuer Zusammenfassungen eingehender Helpdesk-Mails.
#
# Unterstuetzt drei Provider (zentral konfiguriert in den Plugin-Einstellungen):
#   - openai    : OpenAI Chat Completions (Authorization: Bearer)
#   - anthropic : Anthropic Messages API (x-api-key + anthropic-version)
#   - custom    : beliebiger OpenAI-kompatibler Endpunkt (self-hosted:
#                 Ollama, vLLM, LocalAI, LM Studio ...) via Basis-URL
#
# HTTP wie im GraphClient ueber die Ruby-Stdlib (Net::HTTP), ohne Zusatz-Gem,
# ohne Retry. Fehler werden als AiError geworfen; der aufrufende Job faengt sie
# ab und bricht die Mailverarbeitung nicht.

require 'net/http'
require 'uri'
require 'json'

module RedmineExpertHelpdesk
  class AiClient
    class AiError < StandardError
      attr_reader :status, :body

      def initialize(message, status = nil, body = nil)
        super(message)
        @status = status
        @body = body
      end
    end

    class ConfigurationError < AiError; end

    # Der Dienst war nicht erreichbar (Timeout, DNS, TLS, Connection refused) -
    # im Unterschied zu einer Anfrage, die der Provider inhaltlich abgelehnt hat.
    # Der Bearbeiter kann aus dem Unterschied etwas machen: gleich noch einmal
    # versuchen, oder in die Einstellungen schauen.
    class TransportError < AiError; end

    PROVIDERS = %w[openai anthropic custom].freeze

    DEFAULT_ENDPOINTS = {
      'openai'    => 'https://api.openai.com/v1',
      'anthropic' => 'https://api.anthropic.com'
    }.freeze

    ANTHROPIC_VERSION = '2023-06-01'.freeze

    # Solider deutscher Default-Prompt (bearbeiterorientiert). Wird zentral in den
    # Plugin-Einstellungen als Default hinterlegt und kann pro Projekt erweitert
    # oder ersetzt werden (HelpdeskProjectSetting#effective_ai_prompt).
    DEFAULT_PROMPT = <<~PROMPT.freeze
      Du bist ein Assistent im technischen Kundensupport (Helpdesk). Fasse die
      eingehende Kundennachricht fuer die Support-Bearbeiter praegnant zusammen.
      Die Nachricht kann eine weitergeleitete Mail oder ein ganzer Mailverlauf
      sein, in dem die wichtigen Informationen verstreut sind.

      Die Nachricht beginnt mit der Betreffzeile ("Betreff: ..."). Sie ist Teil der
      Kundennachricht - Angaben dort (System, Geraet, Fehler, Zeitpunkt) gehoeren
      genauso in die Zusammenfassung wie Angaben aus dem Text.

      Gib eine kurze Zusammenfassung auf Deutsch als Stichpunkte aus. Nenne nur
      zutreffende Punkte und erfinde keine Informationen:
      - Anliegen: Was ist das eigentliche Problem/Anliegen des Kunden?
      - Wunsch: Was moechte der Kunde konkret erreichen?
      - Bisher versucht: Bereits erwaehnte Loesungsversuche/Schritte.
      - Wichtige Fakten: Fehlermeldungen, Zeitangaben, betroffene Systeme, Nummern.
      - Anhaenge: Falls relevante Anhaenge genannt/enthalten sind, kurz erwaehnen.

      Antworte ausschliesslich mit der Zusammenfassung, ohne Anrede und ohne
      Schlussformel.
    PROMPT

    # Token-Verbrauch des letzten summarize-Aufrufs: { :input => Integer|nil, :output => Integer|nil }.
    attr_reader :last_usage

    # Warum das Modell aufgehoert hat ('stop', 'length', ...), normalisiert ueber
    # beide Provider. Ohne das ist eine bei max_output_tokens abgeschnittene
    # Antwort von einer vollstaendigen nicht zu unterscheiden - bei einer
    # Zusammenfassung Kosmetik, in einer Kundenmail ein halber Satz, der wie
    # eine Zusage aussieht.
    attr_reader :last_finish_reason

    def initialize(settings = nil)
      @settings = settings || Setting.plugin_redmine_expert_helpdesk
      @last_usage = {}
    end

    def enabled?
      @settings['ai_enabled'].to_s == '1'
    end

    def provider
      p = @settings['ai_provider'].to_s.strip
      PROVIDERS.include?(p) ? p : 'openai'
    end

    def model
      @settings['ai_model'].to_s.strip
    end

    def api_key
      @settings['ai_api_key'].to_s.strip
    end

    # Basis-URL: leer = Provider-Default; beim custom-Provider ist sie Pflicht.
    def endpoint
      @settings['ai_endpoint'].to_s.strip.presence || DEFAULT_ENDPOINTS[provider]
    end

    def configured?
      return false unless api_key.present? && model.present?
      return false if provider == 'custom' && @settings['ai_endpoint'].to_s.strip.blank?

      true
    end

    def max_output_tokens
      v = @settings['ai_max_output_tokens'].to_i
      v.positive? ? v : 500
    end

    def read_timeout
      v = @settings['ai_timeout'].to_i
      v.positive? ? v : 60
    end

    # Erzeugt eine Zusammenfassung.
    #   system_prompt : Anweisung an das Modell
    #   user_text     : Mailinhalt (ggf. inkl. Verlauf und Anhang-Text)
    #   image_parts   : [{ :content_type => 'image/png', :data => '<base64>' }] (Vision)
    # Liefert den Zusammenfassungstext (String) oder wirft AiError.
    #   log_context : optional { :request_type, :project_id, :issue_id } – ist es
    #                 gesetzt, wird der Aufruf (Erfolg wie Fehler) in
    #                 HelpdeskAiRequest protokolliert.
    def summarize(system_prompt, user_text, image_parts = [], log_context: nil)
      raise ConfigurationError, 'KI ist nicht konfiguriert (API-Key, Modell oder Endpunkt fehlt)' unless configured?

      # Zuruecksetzen, damit ein Aufruf nie den Abbruchgrund des vorherigen erbt.
      @last_finish_reason = nil
      with_request_log(log_context, :provider => provider, :model => model, :default_type => 'summary') do
        if provider == 'anthropic'
          summarize_anthropic(system_prompt, user_text, image_parts)
        else # openai + custom (OpenAI-kompatibel)
          summarize_openai(system_prompt, user_text, image_parts)
        end
      end
    end

    # --- Embeddings (fuer die Wissensbasis / RAG) --------------------------
    # Anthropic hat keine Embeddings-API; daher eigener Provider (openai/custom).
    # Key/Endpunkt fallen auf die Chat-Konfiguration zurueck, wenn derselbe
    # Provider genutzt wird und kb_embed_* leer ist.
    EMBED_PROVIDERS     = %w[openai custom].freeze
    DEFAULT_EMBED_MODEL = 'text-embedding-3-small'.freeze

    def embed_provider
      p = @settings['kb_embed_provider'].to_s.strip
      EMBED_PROVIDERS.include?(p) ? p : 'openai'
    end

    def embed_model
      @settings['kb_embed_model'].to_s.strip.presence || DEFAULT_EMBED_MODEL
    end

    def embed_api_key
      key = @settings['kb_embed_api_key'].to_s.strip
      return key if key.present?

      embed_provider == provider ? api_key : ''
    end

    def embed_endpoint
      ep = @settings['kb_embed_endpoint'].to_s.strip
      return ep.chomp('/') if ep.present?

      base = embed_provider == provider ? endpoint : DEFAULT_ENDPOINTS[embed_provider].to_s
      base.to_s.chomp('/')
    end

    def embed_configured?
      embed_api_key.present? && embed_model.present? && embed_endpoint.present?
    end

    # Liefert den Embedding-Vektor (Array<Float>) fuer text oder wirft AiError.
    #   log_context : optional { :request_type, :project_id, :issue_id } – wie bei summarize.
    def embed(text, log_context: nil)
      raise ConfigurationError, 'Embeddings sind nicht konfiguriert (Key/Modell/Endpunkt fehlt)' unless embed_configured?

      with_request_log(log_context, :provider => embed_provider, :model => embed_model, :default_type => 'kb_embed') do
        body = post_json("#{embed_endpoint}/embeddings",
                         { 'model' => embed_model, 'input' => text.to_s },
                         { 'Authorization' => "Bearer #{embed_api_key}" })
        vec = body.dig('data', 0, 'embedding')
        raise AiError.new('Leere Embedding-Antwort vom Provider', nil, body.to_s) if vec.blank?

        # Embedding-Verbrauch (bislang verworfen) mitschreiben: nur Input-Tokens.
        usage = body['usage'] || {}
        @last_usage = { :input => usage['prompt_tokens'] || usage['total_tokens'], :output => nil }
        vec
      end
    end

    # --- Reranking (cross-encoder, for the knowledge base / RAG) ----------
    # Second retrieval stage: the vector search is a bi-encoder and ranks on
    # whole-text proximity, so a ticket that merely shares vocabulary with the
    # query can outrank the one describing the same fault. A cross-encoder
    # scores query/document *pairs* and is far more precise - too expensive for
    # a whole collection, which is why it only ever sees a shortlist.
    #
    # Same provider as the embeddings (bge-m3 and bge-reranker-v2-m3 sit on one
    # base URL), so endpoint and key fall back to the kb_embed_* configuration
    # and a working knowledge base needs nothing but the toggle.
    DEFAULT_RERANK_MODEL   = 'bge-reranker-v2-m3'.freeze
    DEFAULT_RERANK_TIMEOUT = 10

    def rerank_enabled?
      @settings['kb_rerank_enabled'].to_s == '1'
    end

    # Every reader falls back to a default in code, not only through init.rb's
    # :default hash: a key added there reads nil on an existing installation
    # until the settings form has been saved once more.
    def rerank_model
      @settings['kb_rerank_model'].to_s.strip.presence || DEFAULT_RERANK_MODEL
    end

    def rerank_endpoint
      ep = @settings['kb_rerank_endpoint'].to_s.strip
      return ep.chomp('/') if ep.present?

      embed_endpoint
    end

    def rerank_api_key
      key = @settings['kb_rerank_api_key'].to_s.strip
      return key if key.present?

      embed_api_key
    end

    def rerank_timeout
      v = @settings['kb_rerank_timeout'].to_i
      v.positive? ? v : DEFAULT_RERANK_TIMEOUT
    end

    def rerank_configured?
      rerank_enabled? && rerank_api_key.present? && rerank_model.present? && rerank_endpoint.present?
    end

    # Scores documents (Array<String>) against query and returns
    #   [{ :index => Integer, :score => Float }, ...]
    # sorted descending, or raises AiError. :index points back into the
    # documents array that was passed in.
    #   log_context : optional { :project_id, :issue_id, ... } - as for embed.
    def rerank(query, documents, log_context: nil)
      raise ConfigurationError, 'Reranking ist nicht konfiguriert (Key/Modell/Endpunkt fehlt)' unless rerank_configured?

      docs = Array(documents).map(&:to_s)
      return [] if docs.empty?

      with_request_log(log_context, :provider => embed_provider, :model => rerank_model, :default_type => 'kb_rerank') do
        body = post_json("#{rerank_endpoint}/rerank",
                         { 'model' => rerank_model, 'query' => query.to_s, 'documents' => docs },
                         { 'Authorization' => "Bearer #{rerank_api_key}" },
                         :read_timeout => rerank_timeout)
        rows = parse_rerank_rows(body, docs.size)
        raise AiError.new('Leere Rerank-Antwort vom Provider', nil, body.to_s) if rows.empty?

        usage = (body.is_a?(Hash) ? body['usage'] : nil) || {}
        @last_usage = { :input => usage['total_tokens'] || usage['prompt_tokens'], :output => nil }
        rows.sort_by { |r| -r[:score] }
      end
    end

    private

    # The provider documents the request only. Both common response shapes are
    # read, so swapping the runtime behind the same URL cannot silently shift
    # the scoring:
    #   Jina/Cohere (vLLM, Infinity):  { "results": [{ "index", "relevance_score" }] }
    #   TEI native:                    [{ "index", "score" }]
    def parse_rerank_rows(body, doc_count)
      raw = body.is_a?(Array) ? body : Array(body.is_a?(Hash) ? body['results'] : nil)
      rows = raw.filter_map do |r|
        next unless r.is_a?(Hash)

        idx = r['index']
        next if idx.nil?

        idx = idx.to_i
        next unless idx >= 0 && idx < doc_count

        score = r.key?('relevance_score') ? r['relevance_score'] : r['score']
        next if score.nil?

        { :index => idx, :score => score.to_f }
      end
      normalize_rerank_scores(rows)
    end

    # bge-reranker-v2-m3 is a cross-encoder; its raw output is a logit. Some
    # runtimes squash it, others do not - the provider we measured
    # (api.ai.net.de) does NOT: one and the same query returned values from
    # +5.97 (identical text) down to -10.99 (entirely unrelated). Without the
    # normalisation kb_rerank_min_score would be silently inert there (every
    # value below 1 passes), and without any error, because the threshold is
    # calibrated on 0..1.
    #
    # The sigmoid is strictly monotonic, so the ranking never changes. It is
    # applied only when some value actually falls outside 0..1, so an already
    # normalised response passes through untouched.
    def normalize_rerank_scores(rows)
      return rows if rows.empty? || rows.all? { |r| r[:score] >= 0.0 && r[:score] <= 1.0 }

      rows.map { |r| r.merge(:score => 1.0 / (1.0 + Math.exp(-r[:score]))) }
    end

    # --- OpenAI / OpenAI-kompatibel (custom) -------------------------------
    def summarize_openai(system_prompt, user_text, image_parts)
      content = user_text
      if image_parts.any?
        content = [{ 'type' => 'text', 'text' => user_text.to_s }]
        image_parts.each do |img|
          content << {
            'type'      => 'image_url',
            'image_url' => { 'url' => "data:#{img[:content_type]};base64,#{img[:data]}" }
          }
        end
      end

      # OpenAI (offiziell) verlangt fuer GPT-5-/o-Modelle 'max_completion_tokens' und
      # lehnt 'max_tokens' mit HTTP 400 ab; es funktioniert auch fuer aeltere Modelle
      # (gpt-4o-mini ...). Self-hosted OpenAI-kompatible Server (Ollama/vLLM/LocalAI)
      # verstehen dagegen meist nur 'max_tokens' -> beim custom-Provider dabei bleiben.
      token_param = provider == 'openai' ? 'max_completion_tokens' : 'max_tokens'
      payload = {
        'model'     => model,
        token_param => max_output_tokens,
        'messages'  => [
          { 'role' => 'system', 'content' => system_prompt.to_s },
          { 'role' => 'user',   'content' => content }
        ]
      }

      body = post_json("#{endpoint.chomp('/')}/chat/completions", payload,
                       { 'Authorization' => "Bearer #{api_key}" })
      usage = body['usage'] || {}
      @last_usage = { :input => usage['prompt_tokens'], :output => usage['completion_tokens'] }
      @last_finish_reason = body.dig('choices', 0, 'finish_reason').to_s.presence
      text = body.dig('choices', 0, 'message', 'content').to_s.strip
      raise AiError.new('Leere Antwort vom KI-Provider', nil, body.to_s) if text.blank?

      text
    end

    # --- Anthropic Messages API --------------------------------------------
    def summarize_anthropic(system_prompt, user_text, image_parts)
      content = user_text
      if image_parts.any?
        content = [{ 'type' => 'text', 'text' => user_text.to_s }]
        image_parts.each do |img|
          content << {
            'type'   => 'image',
            'source' => { 'type' => 'base64', 'media_type' => img[:content_type], 'data' => img[:data] }
          }
        end
      end

      payload = {
        'model'      => model,
        'max_tokens' => max_output_tokens,
        'system'     => system_prompt.to_s,
        'messages'   => [{ 'role' => 'user', 'content' => content }]
      }

      body = post_json("#{endpoint.chomp('/')}/v1/messages", payload,
                       { 'x-api-key' => api_key, 'anthropic-version' => ANTHROPIC_VERSION })
      usage = body['usage'] || {}
      @last_usage = { :input => usage['input_tokens'], :output => usage['output_tokens'] }
      # Anthropic says 'max_tokens'; normalise to OpenAI's 'length' so callers
      # only ever compare against one vocabulary.
      raw_stop = body['stop_reason'].to_s
      @last_finish_reason = raw_stop == 'max_tokens' ? 'length' : raw_stop.presence
      text = Array(body['content']).map { |c| c['text'] }.compact.join.strip
      raise AiError.new('Leere Antwort vom KI-Provider', nil, body.to_s) if text.blank?

      text
    end

    # Netzwerkfehler, die Net::HTTP wirft und die vor dem Antwortentwurf niemand
    # gesehen hat: die Jobs laufen im Hintergrund, dort landet alles im Log. Aus
    # einem Web-Request heraus wuerde eine unbehandelte Ausnahme die HTML-
    # Fehlerseite liefern, und der JSON-Client im Browser zeigt dem Bearbeiter
    # "Unexpected token '<'".
    NETWORK_ERRORS = [Net::OpenTimeout, Net::ReadTimeout, SocketError,
                      Errno::ECONNREFUSED, Errno::ECONNRESET, Errno::EHOSTUNREACH,
                      OpenSSL::SSL::SSLError].freeze

    # POST JSON, parse JSON, raise AiError on non-2xx. Analog zu GraphClient#request.
    # read_timeout: overrides this call's time budget (reranking has its own,
    # much tighter than a text generation).
    #
    # The connect phase is bounded by whatever budget applies, never by the fixed
    # 15 s alone: a blackholed host spends its time connecting, not reading, so a
    # call given 5 s could otherwise block for 20. Every synchronous caller sizes
    # something on these numbers - the answer draft sizes the lock that stops a
    # second paid draft starting while the first still runs - and a bound that
    # only covers the read phase is not a bound.
    #
    # extra_headers is passed as a hash literal at every call site - without the
    # braces Ruby 3 would read the trailing hash as keyword arguments, now that
    # this method has one.
    DEFAULT_OPEN_TIMEOUT = 15

    def post_json(url, payload, extra_headers = {}, read_timeout: nil)
      budget = read_timeout || self.read_timeout
      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == 'https')
      http.open_timeout = [DEFAULT_OPEN_TIMEOUT, budget].min
      http.read_timeout = budget

      req = Net::HTTP::Post.new(uri)
      req['Content-Type'] = 'application/json'
      req['Accept'] = 'application/json'
      extra_headers.each { |k, v| req[k] = v }
      req.body = payload.to_json

      response = http.request(req)
      unless response.is_a?(Net::HTTPSuccess)
        raise AiError.new("KI-Anfrage fehlgeschlagen (HTTP #{response.code})", response.code.to_i, response.body)
      end

      JSON.parse(response.body)
    rescue JSON::ParserError => e
      raise AiError.new("KI-Antwort nicht lesbar: #{e.message}")
    rescue *NETWORK_ERRORS => e
      raise TransportError.new("KI-Dienst nicht erreichbar: #{e.class}", nil, e.message)
    end

    # Fuehrt den KI-Aufruf aus und protokolliert ihn (Erfolg wie Fehler) in
    # HelpdeskAiRequest, sofern ein log_context uebergeben wurde. Der Block setzt
    # @last_usage; die Token werden nach erfolgreichem yield ausgelesen. Ohne
    # Kontext (nil) wird nur ausgefuehrt, nicht protokolliert (rueckwaertskompatibel).
    def with_request_log(context, provider:, model:, default_type:)
      return yield if context.nil?

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      begin
        result = yield
        log_ai_request(context, :provider => provider, :model => model, :default_type => default_type,
                       :duration_ms => elapsed_ms(started), :success => true,
                       :input => @last_usage[:input], :output => @last_usage[:output])
        result
      rescue AiError => e
        log_ai_request(context, :provider => provider, :model => model, :default_type => default_type,
                       :duration_ms => elapsed_ms(started), :success => false,
                       :error_class => e.class.name, :http_status => e.status)
        raise
      rescue => e
        log_ai_request(context, :provider => provider, :model => model, :default_type => default_type,
                       :duration_ms => elapsed_ms(started), :success => false, :error_class => e.class.name)
        raise
      end
    end

    def elapsed_ms(started)
      ((Process.clock_gettime(Process::CLOCK_MONOTONIC) - started) * 1000).round
    end

    # Schreibt eine Protokollzeile. Fehler hier duerfen den KI-Flow nie brechen.
    def log_ai_request(context, provider:, model:, default_type:, duration_ms:, success:,
                       input: nil, output: nil, error_class: nil, http_status: nil)
      HelpdeskAiRequest.create!(
        :request_type  => (context[:request_type].presence || default_type).to_s,
        :provider      => provider,
        :model         => model,
        :project_id    => context[:project_id],
        :issue_id      => context[:issue_id],
        # Nur der Antwortentwurf setzt das; die Jobs laufen ohne handelnden Nutzer.
        :user_id       => context[:user_id],
        :input_tokens  => input,
        :output_tokens => output,
        :duration_ms   => duration_ms,
        :success       => success,
        :error_class   => error_class,
        :http_status   => http_status
      )
    rescue => e
      Rails.logger.warn("[helpdesk][ai] Nutzungs-Protokoll konnte nicht gespeichert werden: #{e.class}: #{e.message}")
    end
  end
end
