# Knowledge-base reranker demo

Synthetic data and two scripts that measure how the retrieval settings behave on *your*
embeddings and reranker models. The numbers in the main README
(*Knowledge base (RAG) → Tuning the reranker threshold*) were produced with these scripts.

- `dataset.json` — 22 solved-ticket entries (German, typical helpdesk faults, grouped so that
  several entries share vocabulary with each other) and 12 customer-style queries. For 8 queries
  the correct entry is known; 4 have **no** correct entry and should return nothing.
- `seed.rb` — creates the private project `kb-reranker-demo` with one closed ticket and one
  approved knowledge-base entry per dataset entry and embeds them. Idempotent; entries removed from
  or renamed in `dataset.json` are deleted (ticket, entry and vector point) on the next run.
- `experiment.rb` — runs every query through the plugin's real `KnowledgeRetrieval.search`
  under several settings and prints a per-query view (cosine vs. reranker score) and a
  scorecard per configuration.

Requirements: the knowledge base is enabled and configured centrally (vector store, embeddings,
and — for the reranker rows — `kb_rerank_*`). The scripts reuse those settings and only override
`kb_rerank_enabled`, `kb_min_score`, `kb_rerank_min_score`, `kb_top_k` (3), `kb_min_results` (1)
and `kb_rerank_candidates` (20).

## Run (local Docker stack, from the parent `redmine-expert` checkout)

```bash
# demo_run <script> [extra "docker compose run" options, e.g. -e THRESHOLDS=0.05,0.1,0.2]
demo_run() {
  local script=$1; shift
  docker compose run --rm --no-deps \
    -v "$PWD/plugins/redmine_expert_helpdesk/docs/kb_reranker_demo:/demo:ro" \
    -e REDMINE_NO_DB_MIGRATE=1 -e REDMINE_PLUGINS_MIGRATE=0 "$@" \
    redmine-expert rails runner "/demo/$script"
}

demo_run seed.rb                                     # once (or after editing dataset.json)
demo_run experiment.rb                               # default set of thresholds
demo_run experiment.rb -e THRESHOLDS=0.05,0.1,0.2    # your own set
```

Outside Docker: `DEMO_DIR=/path/to/kb_reranker_demo bundle exec rails runner /path/to/kb_reranker_demo/seed.rb`
(same for `experiment.rb`).

Each run sends one embeddings request per query and configuration and, for the reranker rows,
one rerank request (a few hundred calls in total); they show up as `kb_retrieve` / `kb_rerank`
in the AI statistics of the demo project. Remove the project when done
(*Administration → Projects → Delete*); its vectors go with the next *Rebuild index* /
`kb_reembed`, or delete the Qdrant collection `helpdesk_kb_p<project id>`.

To measure your own situation, replace the entries and queries with anonymised examples from
your helpdesk: queries phrased the way customers write, and a few that have no answer in the
knowledge base. The unanswerable ones are what tells you where the bar has to sit.
