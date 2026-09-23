# Shared RAG retrieval for the knowledge base.
#
# Extracted from HelpdeskAiSummaryJob so the summary job and the answer drafter
# search the same way. The twenty lines below are not mechanical: they encode
# three settings defaults, the self-hit rejection, the all-or-nothing
# min_results rule and a blanket rescue. Duplicated, the meaning of
# kb_min_score drifts between the callers within two releases.
#
# What stays with the caller is the gate that differs per feature: the summary
# job asks whether the project wants proposals displayed, the drafter asks
# whether answer drafts are enabled. Only the global kb_enabled? switch and the
# "is anything configured at all" check live here.
module RedmineExpertHelpdesk
  module KnowledgeRetrieval
    DEFAULT_TOP_K       = 3
    DEFAULT_MIN_RESULTS = 1
    QUERY_MAX_CHARS     = 8_000

    # Zweite Stufe (Cross-Encoder). Die Defaults stehen hier und nicht nur im
    # :default-Hash von init.rb: ein dort neu ergaenzter Schluessel liefert auf
    # einer bestehenden Installation nil, bis das Einstellungsformular einmal
    # neu gespeichert wurde - kb_rerank_min_score waere dann 0.0 und liesse
    # jeden Treffer durch.
    DEFAULT_RERANK_CANDIDATES = 20
    DEFAULT_RERANK_MIN_SCORE  = 0.2
    RERANK_DOC_MAX_CHARS      = 2_000

    module_function

    # Similar solved tickets from THE PROJECT'S OWN knowledge base (isolation is
    # enforced by the store). Returns [] unless enough hits clear the score
    # threshold - an all-or-nothing rule, so a single weak match never poses as
    # grounding. Errors never reach the caller: retrieval is an enrichment, and
    # a broken vector store must not take the surrounding feature down with it.
    #
    # min_score overrides the configured kb_min_score; the answer drafter passes
    # a stricter value, because a weak hit in a private summary is noise while a
    # weak hit in a customer mail is a false promise.
    # raise_on_error is for the answer draft. The jobs want a broken vector store
    # to be invisible, but the drafter turns an empty result into "no matching
    # knowledge-base entry" - which would be a lie, and would send the agent
    # looking for the entry they know is there instead of at the store.
    # diagnostics: an optional Hash the caller owns. When given, it is filled
    # with :best_score and :candidates - what retrieval *saw* before the score
    # filter. The answer draft needs it to tell an agent whether the best match
    # was a near miss (lower the bar) or nothing close (write it yourself);
    # without it, both look identical from the outside.
    def search(issue, settings, client, query_text,
               request_type: 'kb_retrieve', min_score: nil, store: nil, user_id: nil,
               raise_on_error: false, diagnostics: nil)
      return [] unless AiFeatures.kb_enabled?
      return [] if query_text.blank?

      # An injected store lets the caller tighten the network timeouts: the
      # answer draft runs inside a web request, the jobs do not.
      store ||= KnowledgeStore.for(settings)
      return [] unless store.configured? && client.embed_configured?

      top_k       = positive_or(settings['kb_top_k'].to_i, DEFAULT_TOP_K)
      min_results = positive_or(settings['kb_min_results'].to_i, DEFAULT_MIN_RESULTS)

      # With a reranker the vector search is only the cheap first stage: it
      # over-fetches a shortlist and does not judge it, because its score is
      # about to be replaced. Without one it stays the single stage and fetches
      # exactly what the caller gets.
      reranking  = client.respond_to?(:rerank_configured?) && client.rerank_configured?
      candidates = if reranking
                     [positive_or(settings['kb_rerank_candidates'].to_i, DEFAULT_RERANK_CANDIDATES), top_k].max
                   else
                     top_k
                   end

      vec = client.embed(query_text.to_s[0, QUERY_MAX_CHARS],
                         :log_context => { :request_type => request_type, :user_id => user_id,
                                           :project_id => issue.project_id, :issue_id => issue.id })
      hits = store.search(issue.project_id, vec, candidates)
      # The ticket must not retrieve itself: it is in the store once closed, and
      # its own solution is not evidence for its own answer. Rejected before the
      # score filter so a self-hit never poses as the "best match" either - and
      # before the reranker, so we never pay to score a document we then drop.
      hits = hits.reject { |h| (h[:payload] || {})['issue_id'].to_i == issue.id }

      reranked = false
      hits, reranked = apply_rerank(hits, client, query_text, issue, user_id) if reranking && hits.any?

      # The threshold follows the score, not the setting: when the reranker
      # failed, hits still carry their cosine score and must be judged by the
      # cosine bar. Deciding this from kb_rerank_enabled instead would gate
      # similarities with a cross-encoder threshold on every outage.
      threshold = min_score || if reranked
                                 float_or(settings['kb_rerank_min_score'], DEFAULT_RERANK_MIN_SCORE)
                               else
                                 settings['kb_min_score'].to_f
                               end
      if diagnostics.is_a?(Hash)
        diagnostics[:candidates]        = hits.size
        diagnostics[:best_score]        = hits.map { |h| h[:score].to_f }.max
        diagnostics[:threshold]         = threshold
        diagnostics[:reranked]          = reranked
        diagnostics[:best_vector_score] = hits.map { |h| (h[:vector_score] || h[:score]).to_f }.max
      end
      # first(top_k) is load-bearing once we over-fetch: the store was asked for
      # a shortlist, the caller wants top_k. It is a no-op without a reranker.
      hits = hits.select { |h| h[:score].to_f >= threshold }.first(top_k)
      hits.size >= min_results ? hits : []
    rescue => e
      Rails.logger.warn("[helpdesk][kb] Retrieval fehlgeschlagen (Issue ##{issue.id}): #{e.message}")
      raise if raise_on_error

      []
    end

    # Numbered "Problem:/Loesung:" lines for a prompt block.
    #
    # with_issue_ids is load-bearing, not cosmetic. The summary is internal and
    # names the ticket so the agent can follow it up; a customer-facing draft
    # must not, because a foreign ticket number discloses the existence - and by
    # inference the content - of another customer's ticket.
    def format_hits(hits, with_issue_ids:)
      hits.each_with_index.map do |h, i|
        p      = h[:payload] || {}
        origin = with_issue_ids ? " (Ticket ##{p['issue_id']})" : ''
        "#{i + 1}.#{origin} Problem: #{p['problem']}\n   Loesung: #{p['solution']}"
      end.join("\n")
    end

    # Bewertet die Vorauswahl mit dem Cross-Encoder neu und liefert
    # [hits, reranked?]. Der Reranker ist eine Verbesserung, keine Bedingung:
    # faellt er aus, bleiben die Vektortreffer brauchbar, und der Aufrufer
    # bekommt sie in Vektor-Reihenfolge samt Kosinus-Score zurueck. Deshalb
    # faengt diese Methode ihre Fehler selbst, statt sie in den Sammel-rescue
    # von search laufen zu lassen, der die Suche als Ganzes aufgibt.
    #
    # Bewertet wird nur 'problem' - das ist der Text, der auch eingebettet
    # wurde. Die Loesung mitzugeben brachte Treffer nach vorn, deren *Fix*
    # zufaellig die Worte der Anfrage teilt, waehrend der Fehler ein anderer
    # ist; genau den Fehlgriff soll die Stufe verhindern.
    def apply_rerank(hits, client, query_text, issue, user_id)
      docs = hits.map { |h| (h[:payload] || {})['problem'].to_s[0, RERANK_DOC_MAX_CHARS] }
      rows = client.rerank(query_text.to_s[0, QUERY_MAX_CHARS], docs,
                           :log_context => { :user_id => user_id, :project_id => issue.project_id,
                                             :issue_id => issue.id })
      return [hits, false] if rows.blank?

      reordered = rows.filter_map do |row|
        hit = hits[row[:index].to_i]
        next unless hit

        hit.merge(:vector_score => hit[:score], :score => row[:score].to_f)
      end
      return [hits, false] if reordered.empty?

      [reordered, true]
    rescue => e
      Rails.logger.warn("[helpdesk][kb] Reranking fehlgeschlagen (Issue ##{issue.id}), " \
                        "Vektor-Reihenfolge bleibt: #{e.message}")
      [hits, false]
    end

    def positive_or(value, fallback)
      value.positive? ? value : fallback
    end

    # Wie positive_or, aber fuer Schwellwerte: hier ist 0.0 ein gueltiger Wert,
    # ein fehlender Schluessel aber nicht. Unterschieden wird daher am leeren
    # String / nil, nicht am Zahlenwert.
    def float_or(value, fallback)
      value.to_s.strip.present? ? value.to_f : fallback
    end
  end
end
