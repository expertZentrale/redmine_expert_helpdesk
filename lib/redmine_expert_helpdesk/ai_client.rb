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
    def summarize(system_prompt, user_text, image_parts = [])
      raise ConfigurationError, 'KI ist nicht konfiguriert (API-Key, Modell oder Endpunkt fehlt)' unless configured?

      if provider == 'anthropic'
        summarize_anthropic(system_prompt, user_text, image_parts)
      else # openai + custom (OpenAI-kompatibel)
        summarize_openai(system_prompt, user_text, image_parts)
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
    def embed(text)
      raise ConfigurationError, 'Embeddings sind nicht konfiguriert (Key/Modell/Endpunkt fehlt)' unless embed_configured?

      body = post_json("#{embed_endpoint}/embeddings",
                       { 'model' => embed_model, 'input' => text.to_s },
                       'Authorization' => "Bearer #{embed_api_key}")
      vec = body.dig('data', 0, 'embedding')
      raise AiError.new('Leere Embedding-Antwort vom Provider', nil, body.to_s) if vec.blank?

      vec
    end

    private

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
                       'Authorization' => "Bearer #{api_key}")
      usage = body['usage'] || {}
      @last_usage = { :input => usage['prompt_tokens'], :output => usage['completion_tokens'] }
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
                       'x-api-key' => api_key, 'anthropic-version' => ANTHROPIC_VERSION)
      usage = body['usage'] || {}
      @last_usage = { :input => usage['input_tokens'], :output => usage['output_tokens'] }
      text = Array(body['content']).map { |c| c['text'] }.compact.join.strip
      raise AiError.new('Leere Antwort vom KI-Provider', nil, body.to_s) if text.blank?

      text
    end

    # POST JSON, parse JSON, raise AiError on non-2xx. Analog zu GraphClient#request.
    def post_json(url, payload, extra_headers = {})
      uri = URI(url)
      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == 'https')
      http.open_timeout = 15
      http.read_timeout = read_timeout

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
    end
  end
end
