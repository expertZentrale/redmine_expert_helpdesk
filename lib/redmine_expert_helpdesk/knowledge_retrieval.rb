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

    # Second stage (cross-encoder). The defaults live here and not only in
    # init.rb's :default hash: a key added there reads nil on an existing
    # installation until the settings form has been saved once more -
    # kb_rerank_min_score would then be 0.0 and let every hit through.
    DEFAULT_RERANK_CANDIDATES = 20
    DEFAULT_RERANK_MIN_SCORE  = 0.2
    # The cosine gate had the same footgun one branch away: to_f reads a German
    # "0,5" as 0.0 and switches the gate off entirely, so it goes through the
    # same strict parser and needs the same coded default.
    DEFAULT_MIN_SCORE         = 0.5
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
                                 float_or(settings['kb_min_score'], DEFAULT_MIN_SCORE)
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

    # Re-scores the shortlist with the cross-encoder and returns
    # [hits, reranked?]. The reranker is an improvement, not a precondition: if
    # it fails the vector hits are still usable, and the caller gets them in
    # vector order with their cosine score. That is why this method catches its
    # own errors instead of letting them reach search's blanket rescue, which
    # gives up on the search as a whole.
    #
    # Only 'problem' is scored - the text that was embedded. Feeding the
    # solution in as well pulled up hits whose *fix* happens to share the
    # query's words while the fault is a different one; that is precisely the
    # mistake this stage exists to prevent.
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

    # Like positive_or, but for thresholds: here 0.0 is a valid value while a
    # missing key is not. The two are told apart by the blank string / nil,
    # not by the number.
    #
    # Parsed strictly, and anything that is not a plain 0..1 number falls back to
    # the shipped default. This is a free-form central setting and the only gate
    # on the proposals, so to_f would be the wrong tool twice over: it reads
    # "oops" as 0.0 and lets every candidate through, and it reads "50%" as 50.0
    # and lets none through. Failing to the default is the only safe direction.
    def float_or(value, fallback)
      # The admin UI is German, so "0,2" is what an admin is liable to type.
      # HelpdeskProjectSetting.parse_ai_answer_min_score does the same for the
      # sibling threshold; without it a comma is not a near miss but a silent
      # reset to the default.
      raw = value.to_s.strip.tr(',', '.')
      return fallback if raw.blank?

      v = Float(raw)
      return fallback unless v.finite? && v >= 0.0 && v <= 1.0

      v
    rescue ArgumentError, TypeError
      fallback
    end
  end
end
