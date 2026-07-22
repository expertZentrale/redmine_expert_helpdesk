# Vektor-Store fuer die Wissensbasis (RAG). Zwei austauschbare Backends hinter
# einer gemeinsamen Schnittstelle, per zentraler Einstellung kb_backend gewaehlt:
#   - qdrant   : externe REST-API (Net::HTTP, kein Zusatz-Gem), 1 Collection/Projekt
#   - pgvector : externe Postgres-DB mit pgvector (benoetigt gem 'pg', gekapselt)
#
# Strikte Projekt-Isolation: jede Methode nimmt project_id als erstes Argument.
# Qdrant isoliert ueber eine eigene Collection je Projekt; pgvector ueber ein
# zwingendes  WHERE project_id = $1  auf dem einzigen Suchpfad.
#
# Einheitliche Rueckgabe von search:
#   [ { :id => <entry_id>, :score => Float(0..1), :payload => { 'issue_id'=>, 'problem'=>, 'solution'=> } }, ... ]

require 'net/http'
require 'uri'
require 'json'

module RedmineExpertHelpdesk
  module KnowledgeStore
    class StoreError < StandardError; end

    # Waehlt das Backend gemaess zentraler Einstellung kb_backend.
    def self.for(settings = nil)
      settings ||= Setting.plugin_redmine_expert_helpdesk
      case settings['kb_backend'].to_s
      when 'pgvector' then PgvectorStore.new(settings)
      else                 QdrantStore.new(settings)
      end
    end

    # ---- Qdrant -----------------------------------------------------------
    class QdrantStore
      def initialize(settings)
        @settings = settings
      end

      def base_url
        @settings['kb_qdrant_url'].to_s.strip.chomp('/')
      end

      def configured?
        base_url.present?
      end

      def collection(project_id)
        "helpdesk_kb_p#{project_id.to_i}"
      end

      # Legt die Collection an, falls sie fehlt (Vektorgroesse = Embedding-Dim).
      def ensure_ready!(project_id, dims)
        name = collection(project_id)
        res = request(:get, "/collections/#{name}", nil, :allow_404 => true)
        return if res && res['result']

        request(:put, "/collections/#{name}",
                { :vectors => { :size => dims.to_i, :distance => 'Cosine' } })
      end

      def upsert(project_id, id, vector, payload)
        request(:put, "/collections/#{collection(project_id)}/points",
                { :points => [{ :id => id.to_i, :vector => vector, :payload => payload }] })
      end

      def search(project_id, vector, top_k)
        res = request(:post, "/collections/#{collection(project_id)}/points/search",
                      { :vector => vector, :limit => top_k.to_i, :with_payload => true },
                      :allow_404 => true)
        return [] unless res && res['result']

        res['result'].map do |r|
          { :id => r['id'], :score => r['score'].to_f, :payload => r['payload'] || {} }
        end
      end

      def delete(project_id, id)
        request(:post, "/collections/#{collection(project_id)}/points/delete",
                { :points => [id.to_i] }, :allow_404 => true)
      end

      def reset!(project_id)
        request(:delete, "/collections/#{collection(project_id)}", nil, :allow_404 => true)
      end

      private

      def request(method, path, payload = nil, allow_404: false)
        uri = URI("#{base_url}#{path}")
        http = Net::HTTP.new(uri.host, uri.port)
        http.use_ssl = (uri.scheme == 'https')
        http.open_timeout = 10
        http.read_timeout = 30

        req = case method
              when :get    then Net::HTTP::Get.new(uri)
              when :put    then Net::HTTP::Put.new(uri)
              when :post   then Net::HTTP::Post.new(uri)
              when :delete then Net::HTTP::Delete.new(uri)
              end
        req['Content-Type'] = 'application/json'
        key = @settings['kb_qdrant_api_key'].to_s.strip
        req['api-key'] = key if key.present?
        req.body = payload.to_json if payload

        response = http.request(req)
        return nil if allow_404 && response.is_a?(Net::HTTPNotFound)
        unless response.is_a?(Net::HTTPSuccess)
          raise StoreError, "Qdrant-Anfrage fehlgeschlagen (HTTP #{response.code}): #{method.to_s.upcase} #{path} – #{response.body}"
        end

        response.body.present? ? JSON.parse(response.body) : {}
      rescue JSON::ParserError => e
        raise StoreError, "Qdrant-Antwort nicht lesbar: #{e.message}"
      end
    end

    # ---- Postgres + pgvector ---------------------------------------------
    class PgvectorStore
      TABLE = 'helpdesk_kb_vectors'.freeze

      def initialize(settings)
        @settings = settings
      end

      # gem 'pg' ist optional (nur fuer dieses Backend). Fehlt es, gilt der Store
      # als nicht konfiguriert und die Funktion degradiert (Fehler wird geloggt).
      def pg_available?
        require 'pg'
        true
      rescue LoadError
        false
      end

      def configured?
        @settings['kb_pg_url'].to_s.strip.present? && pg_available?
      end

      def ensure_ready!(_project_id, dims)
        conn.exec('CREATE EXTENSION IF NOT EXISTS vector')
        conn.exec(<<~SQL)
          CREATE TABLE IF NOT EXISTS #{TABLE} (
            project_id integer NOT NULL,
            entry_id   integer NOT NULL,
            issue_id   integer,
            problem    text,
            solution   text,
            embedding  vector(#{dims.to_i}),
            PRIMARY KEY (project_id, entry_id)
          )
        SQL
        conn.exec("CREATE INDEX IF NOT EXISTS #{TABLE}_embedding_idx ON #{TABLE} USING hnsw (embedding vector_cosine_ops)")
      end

      def upsert(project_id, id, vector, payload)
        conn.exec_params(
          "INSERT INTO #{TABLE} (project_id, entry_id, issue_id, problem, solution, embedding)
           VALUES ($1, $2, $3, $4, $5, $6::vector)
           ON CONFLICT (project_id, entry_id)
           DO UPDATE SET issue_id = EXCLUDED.issue_id, problem = EXCLUDED.problem,
                         solution = EXCLUDED.solution, embedding = EXCLUDED.embedding",
          [project_id.to_i, id.to_i, payload['issue_id'], payload['problem'], payload['solution'], vector_literal(vector)]
        )
      end

      # Projekt-Isolation: WHERE project_id = $1 ist auf dem einzigen Suchpfad zwingend.
      def search(project_id, vector, top_k)
        res = conn.exec_params(
          "SELECT entry_id, issue_id, problem, solution,
                  1 - (embedding <=> $2::vector) AS score
           FROM #{TABLE}
           WHERE project_id = $1
           ORDER BY embedding <=> $2::vector
           LIMIT $3",
          [project_id.to_i, vector_literal(vector), top_k.to_i]
        )
        res.map do |row|
          { :id => row['entry_id'].to_i, :score => row['score'].to_f,
            :payload => { 'issue_id' => row['issue_id'].to_i, 'problem' => row['problem'], 'solution' => row['solution'] } }
        end
      end

      def delete(project_id, id)
        conn.exec_params("DELETE FROM #{TABLE} WHERE project_id = $1 AND entry_id = $2", [project_id.to_i, id.to_i])
      end

      def reset!(project_id)
        conn.exec_params("DELETE FROM #{TABLE} WHERE project_id = $1", [project_id.to_i]) if table_exists?
      end

      private

      def vector_literal(vector)
        "[#{Array(vector).map(&:to_f).join(',')}]"
      end

      def table_exists?
        conn.exec("SELECT to_regclass('#{TABLE}') AS t").first['t'].present?
      end

      def conn
        @conn ||= begin
          require 'pg'
          PG.connect(@settings['kb_pg_url'].to_s.strip)
        end
      end
    end
  end
end
