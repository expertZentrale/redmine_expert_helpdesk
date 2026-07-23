# GitHub Copilot instructions — redmine_expert_helpdesk

These instructions apply to the whole repository. They mirror `CLAUDE.md` (the fuller
companion doc — read it for deeper architecture notes); keep the two in sync when either changes.

## What this is

A **Redmine plugin** (`redmine_expert_helpdesk`) that turns Microsoft 365 mailboxes into a
helpdesk: incoming mail becomes tickets (or journal replies), agents reply to customers from
the ticket page, and contacts/SLA/phishing detection layer on top. Requires Redmine 5.0+.

The plugin is developed **inside the parent `redmine-expert` deployment repo** (two levels up,
`../../`), which packages plugins, themes and Docker/Kubernetes config. **This repo is NOT a
Redmine checkout** — there is no Gemfile, `rake`, or `config/database.yml` at `../../`. Base
Redmine is supplied by a Docker image; the app only exists inside the running container
(`/usr/src/redmine`), so host-level `bundle exec rake` does not work.

## Hard rules (must follow)

- **Never use `docker exec`** to run commands inside a running container (hard project rule).
  You **may** use `docker-compose` to manage the stack.
- Because the plugin is **`COPY`'d into the image** (see `Dockerfile.dev`), not volume-mounted,
  a plain `restart` does **not** pick up edited source or new routes. Rebuild with
  `docker-compose -f docker-compose.yml up --build` (run from the parent repo root `../../`).
- **Every change must update `CHANGELOG.md`** and, for user-facing changes, **`README.md` (EN)
  and `README.de.md` (DE)** — keep both READMEs in sync.
- Comments, i18n and much documentation are in **German**; match the surrounding language when
  editing.
- **Never edit a shipped migration.** When changing schema, add the next sequential number in
  `db/migrate/` (`001_...` onward).
- Don't hard-code secrets/API keys. Local dev credentials live in `.dev.env` (git-ignored).

## Development workflow (Docker)

Run everything from the **parent repo root** (`../../`).

```bash
# Start / rebuild the local stack (MariaDB + Redmine + phpMyAdmin) — Redmine on :3000
docker-compose -f docker-compose.yml up --build
```

- **Migrations run automatically** on build via `REDMINE_PLUGINS_MIGRATE=1` (see
  `docker-compose.yml`). Manual equivalent (in the container/build context, not the host):
  `bundle exec rake redmine:plugins:migrate NAME=redmine_expert_helpdesk RAILS_ENV=production`.
- A DB dump in `../../redmine_db_dump/` is auto-imported on first MariaDB start.
- To inspect Redmine core behavior, use the Redmine source on GitHub — do **not** `docker exec`.

## Tests

MiniTest (`ActiveSupport::TestCase`); `test/test_helper.rb` loads Redmine's own test helper, so
tests **require a Redmine environment** (the container / a Redmine checkout — they cannot run
standalone here). Inside a Redmine environment:

```bash
bundle exec rake redmine:plugins:test NAME=redmine_expert_helpdesk RAILS_ENV=test
bundle exec ruby -Itest plugins/redmine_expert_helpdesk/test/unit/sla_test.rb
```

The REST API (see `API.md`) can be smoke-tested live against the local stack over HTTP from the
host — source `.dev.env` for `REDMINE_URL` + `REDMINE_API_KEY`, then `curl` with an
`X-Redmine-API-Key` header. Use a `project_id` with the Helpdesk module enabled.

## Triggering mail fetch

No built-in scheduler. Fetch runs via the project settings button (*Helpdesk → Fetch mails now*)
or the API-key-secured global endpoint used by cron: `/helpdesk/fetch_all?key=API-KEY`. The
`fetch_all` cycle also runs the SLA breach check and the phishing-feed sync.

## Architecture

- **`init.rb`** — plugin bootstrap: settings (Azure tenant/client/secret, fetch key, phishing
  feeds), the `:helpdesk` project module + permissions, project menu, activity provider.
  **Patches are prepended directly in `init.rb`** (guarded by `unless ...include?`), *not* via
  `to_prepare` (the comment there explains why).
- **`lib/redmine_expert_helpdesk/`** — core:
  - `graph_client.rb` — Microsoft Graph REST client (OAuth2 client-credentials, token cached).
  - `mail_processor.rb` — the heart: per mailbox, hands raw MIME to Redmine's own `MailHandler`
    (which does ticket creation / reply matching via `In-Reply-To`/`[#id]` / attachments /
    user creation), then applies rules, links contact, autoresponder, phishing check, stores
    `.eml`, moves the mail. Reply-vs-new matching is delegated entirely to `MailHandler`.
  - `init_mailer.rb` — outbound "initial" mail (contact-assign / "New Helpdesk Ticket" flow).
  - `template_renderer.rb` — `{{issue.*}}` templating for subjects/headers/footers/autoresponder.
  - `ai_client.rb` — AI provider client (`Net::HTTP`, mirrors `graph_client.rb`) for per-project
    mail summaries: `openai` / `anthropic` / `custom` (OpenAI-compatible, self-hosted). Central
    `ai_*` plugin settings; ships `DEFAULT_PROMPT`. Runs via `HelpdeskAiSummaryJob` (`app/jobs/`,
    ActiveJob) enqueued from `MailProcessor#enqueue_ai_summary` after ingest; opt-in per project
    (`HelpdeskProjectSetting` `ai_summary_enabled`/`ai_summary_scope`/`ai_prompt_mode`/`ai_prompt`/
    `ai_attach_*`/`ai_include_journal`/`ai_include_private_notes`); posts a **private** journal note. Off by default; failures are logged, never
    break ingestion. Token usage (`AiClient#last_usage`) is stored per note in `HelpdeskAiSummary`
    (migration 028) and shown as a 🤖 token badge in the note's journal header (via the
    `_issue_sidebar` badge JS, like the to/cc/bcc recipient badges). Manual re-run via
    `HelpdeskAiController#regenerate` (sidebar button, `send_helpdesk_reply`) enqueues the job
    with `force: true` (bypasses per-project enable/scope).
  - `knowledge_store.rb` / `knowledge_extractor.rb` — RAG knowledge base from resolved tickets.
    On close (`Issue#after_save` in `patches/issue_patch.rb` — catches single + bulk + API) or rake
    (`kb_backfill`/`kb_reembed`), `HelpdeskKnowledgeIngestJob` extracts
    `{problem, solution}`, stores a `HelpdeskKnowledgeEntry` (SQL system of record), and embeds
    approved entries (`AiClient#embed`) into the vector store. `KnowledgeStore.for(settings)` picks
    `QdrantStore` (REST, no gem) or `PgvectorStore` (`gem 'pg'`, guarded) per `kb_backend`. **Strict
    per-project isolation** (collection / enforced `project_id`). `HelpdeskAiSummaryJob` injects a
    "Lösungsvorschlag" and/or writes `HelpdeskKbProposal` rows (per-project `kb_ingest_mode` /
    `kb_proposal_display`; `HelpdeskKnowledgeController` for manual approve/ingest). Migrations 030–032.
    pgvector needs `gem 'pg'` in the deployment (kept out of `PluginGemfile`).
  - `business_hours.rb` / `sla.rb` / `sla_breach_check.rb` — SLA in *business minutes*.
  - `phish*.rb` / `phishing_scanner.rb` — PhishTank + Phishing.Database mirror, link scanning
    (decodes Microsoft SafeLinks locally), neutralize/quarantine.
  - `hooks.rb` — `ViewListener` view hooks (customer sidebar card, ticket-header info bar, reply
    form, activity-feed CSS) + `controller_issues_*_after_save` hooks. No Deface.
- **`lib/redmine_expert_helpdesk/patches/`** — `Issue`, `IssueQuery`, `Project`, `ProjectsHelper`
  core extensions (associations, query columns/filters, helpers). Applied in `init.rb`. Mostly
  `prepend`; **`ProjectsHelperPatch` and `QueriesHelperPatch` use UnboundMethod capture** (not
  prepend/super) for `project_settings_tabs` resp. `column_content`, so they coexist with
  `alias_method_chain` plugins (RedmineUP `redmine_contacts_helpdesk`) — prepend/super collides
  there (`super: no superclass method`). Our settings tab is named `expert_helpdesk` (not
  `helpdesk`, which RedmineUP also uses); internal `:tab => 'expert_helpdesk'` redirects match.
- **`app/`** — standard Rails MVC. Controllers map to permissions in `init.rb`'s
  `project_module :helpdesk` block. Key: `helpdesk_fetch`, `helpdesk_replies` (largest —
  MIME / CID inline images / transport choice), `helpdesk_mailboxes`, `helpdesk_contacts`,
  `helpdesk_init`, `helpdesk_project_settings`.
- **`app/models/`** — `HelpdeskMailbox`, `HelpdeskContact`, `HelpdeskMessage` (in/out/init log +
  `.eml`, powers the activity feed), `HelpdeskRule`, `HelpdeskProjectSetting`,
  `HelpdeskSlaPriority`, `HelpdeskTicketInfo`, `HelpdeskPhishingUrl`.

## Key behaviors worth knowing

- **Reply transport is per-mailbox**: `graph` (default — sends full Base64 MIME to preserve CID
  inline images, because Exchange rewrites HTML in the JSON send path) or `smtp` (Redmine SMTP;
  inline images become Base64 data URIs).
- **Redmine version DOM differs**: RM5 journals use `#journal-<id>-notes` / `h4.note-header`;
  RM6/7 use `#change-<id>` / `h4.journal-header` (with `span.journal-info` + `span.journal-meta`).
  View-hook JS that touches journals must handle both.
- Every processed mail is stored as an `.eml` attachment ("Original E-Mail") on the ticket.
- `unknown_user_mode` on the mailbox (`accept`/`create`/`ignore`) controls senders with no
  Redmine user, enforced by `MailHandler`.
- Azure app registration is a one-time external setup; central credentials live under
  *Administration → Plugins → Redmine expert Helpdesk*.
