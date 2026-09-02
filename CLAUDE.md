# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A **Redmine plugin** (`redmine_expert_helpdesk`) that turns Microsoft 365 **or IMAP** mailboxes
into a helpdesk: incoming mail becomes tickets (or journal replies), agents reply to
customers from the ticket page, and contacts/SLA/phishing detection layer on top. Requires
Redmine 5.0+.

This plugin is developed **inside the parent `redmine-expert` deployment repo** (two levels
up, `../../`), which packages plugins, themes and Docker/Kubernetes config. **This repo is
NOT a Redmine checkout** — there is no Gemfile, `rake`, or `config/database.yml` at
`../../`. Base Redmine is supplied by a Docker image; the app only exists inside the running
container (`/usr/src/redmine`), so host-level `bundle exec rake` does not work.

**Language policy:** **code comments are English** (write new comments in English; the surrounding
codebase still has legacy German comments — leave them unless you're already editing that code).
**i18n stays bilingual** (`config/locales/en.yml` + `de.yml`) and the plugin UI is German.
Docs are **English-first with a German mirror kept in sync**: `README.md` (EN) / `README.de.md` (DE),
and `CHANGELOG.md` (EN, authoritative — release notes are generated from it) / `CHANGELOG.de.md` (DE).
Keep each EN/DE pair in sync for user-facing changes.

## Development workflow (Docker)

Run everything from the **parent repo root** (`../../`, i.e. the `redmine-expert` checkout).

```bash
# Start / rebuild the local stack (MariaDB + Redmine + phpMyAdmin) — Redmine on :3000
docker-compose -f docker-compose.yml up --build
```

> **Never use `docker exec` to run commands inside a running container** (hard project
> rule, see parent `README.md`). Claude **may** use `docker-compose` itself to manage the
> stack — e.g. `docker-compose -f docker-compose.yml restart redmine-expert` or
> `... up --build` (rebuild + restart). Code changes, migrations and config updates take
> effect only after a rebuild, because the plugin is **`COPY`'d into the image** (see
> `Dockerfile.dev`), not volume-mounted — a plain `restart` alone does **not** pick up
> edited source or new routes; use `up --build` for that.

- **Migrations run automatically** on container build via `REDMINE_PLUGINS_MIGRATE=1`
  (see `docker-compose.yml`). The manual equivalent (run in the build/container
  context, not on the host) is:
  `bundle exec rake redmine:plugins:migrate NAME=redmine_expert_helpdesk RAILS_ENV=production`.
- A DB dump in `../../redmine_db_dump/` is auto-imported on first MariaDB start.

## Tests

Tests are MiniTest (`ActiveSupport::TestCase`); `test/test_helper.rb` loads Redmine's own
test helper, so they **require a Redmine environment** (the container / a Redmine checkout —
they cannot run standalone in this repo). GitLab CI here handles deployment only, not tests.
Inside a Redmine environment the standard commands are:

```bash
# All plugin tests
bundle exec rake redmine:plugins:test NAME=redmine_expert_helpdesk RAILS_ENV=test

# Single file / single test
bundle exec ruby -Itest plugins/redmine_expert_helpdesk/test/unit/sla_test.rb
bundle exec ruby -Itest plugins/redmine_expert_helpdesk/test/unit/sla_test.rb -n test_reaction_deadline
```

The plugin also ships a rake task for the phishing mirror:
`bundle exec rake redmine_expert_helpdesk:phishtank_sync`.

## Git workflow (feature branches)

`main` is the protected integration branch — **release tags are cut only from merged `main`**, so
do **not** develop features directly on it.

- **Branch per unit of work**, named `type/short-desc` where `type` matches the Conventional-Commit
  style used in the CHANGELOG: `feat/…`, `fix/…`, `chore/…`, `docs/…`, `refactor/…`, `test/…`
  (e.g. `feat/sla-priority-overrides`, `fix/graph-token-refresh`). Branch off the latest `main`.
- **Commit messages** use the same Conventional-Commit prefixes; keep commits focused and include
  the CHANGELOG/README updates the change requires (EN authoritative + DE mirror, per the language
  policy above).
- **Open a PR** into `main`. CI (`ci.yml`, `docker-image.yml`) runs on `main`/PRs and **must pass**
  before merge; describe the change and link it to its CHANGELOG entry.
- **Squash-merge** the PR — one commit per feature keeps `main` history linear. Delete the branch
  after merge.
- **Exception — trivial fixes may commit straight to `main`**: docs/typo/CHANGELOG-only tweaks that
  touch no code and no schema. Anything touching Ruby/JS, migrations, i18n or behavior needs a
  branch + PR.
- **Never rewrite published history** (`main`, or any branch someone else has pulled); rebase only
  your own un-pushed local commits.
- After a feature merges to `main` and is ready to ship, bump `init.rb` + CHANGELOG and cut the tag
  (see *Releases* below).

## Releases (tag-driven)

GitHub Releases are produced only by pushing a semver tag — never on normal pushes/PRs. The plugin
version is the **single source of truth in `init.rb`** (`version '...'`): bump it and commit
first, then tag the same commit and push (`git tag vX.Y.Z && git push origin vX.Y.Z`).
`.github/workflows/release.yml` (triggered on `push: tags: v*`) **verifies** that the `init.rb`
version equals the tag (fails on mismatch), builds `redmine_expert_helpdesk-<version>.{zip,tar.gz}`
(top-level `redmine_expert_helpdesk/` dir, dev files excluded) from the tagged tree, and publishes
the release with notes taken from the CHANGELOG entries added since the previous tag. The two
other workflows (`ci.yml`, `docker-image.yml`) run on `main`/PRs only.

**Every release must also update `docs/redmine_org/`** — the copy-paste sources for the listing at
<https://www.redmine.org/plugins/redmine_expert_helpdesk>. That directory renders **Textile**, not
Markdown (`h3.` headings, `*bold*`, `@code@`, `"label":url`), so these files are written in Textile
and are pasted in unedited. Part of the release commit, not an afterthought:

- `docs/redmine_org/releases/<version>.textile` — new file per release. User-facing changes only;
  the CHANGELOG is the source but this is not a copy of it. Add an *Upgrade notes* section when
  migrations run or behaviour changes.
- `docs/redmine_org/description.textile` — what the plugin *is*; update when a release changes
  what it supports (new backends, new requirements, dropped limitations) and bump the Redmine
  versions under *Requirements* when they move. This one drifts silently: 0.1.6 still advertised
  "only Microsoft O365 is supported" after 0.2.0 had shipped generic IMAP/SMTP.
- `docs/redmine_org/installation.textile` — how to install and run it; update when a release
  changes a step (new migration requirement, new permission or setting, changed endpoint, new gem).
  The directory keeps description and installation notes in **separate fields** — keep them split.

`docs/` is excluded from the release archives, so none of it ships to users.

### REST API smoke tests against local dev

The plugin's REST API (see `API.md`) can be exercised live against the local Docker stack —
no container shell needed, just HTTP from the host.

- **Prereqs**: the stack is running (`docker-compose -f docker-compose.yml up --build` from the
  parent repo root) and the REST web service is enabled in *Administration → Settings → API*.
- **Credentials**: read them from `.dev.env` (git-ignored, local-only) — it holds `REDMINE_URL`
  (default `http://localhost:3000`) and `REDMINE_API_KEY`. Do **not** hard-code the key; source
  the file:

  ```bash
  set -a; . ./.dev.env; set +a   # loads REDMINE_URL + REDMINE_API_KEY

  # List helpdesk tickets of a project (JSON)
  curl -sS -H "X-Redmine-API-Key: $REDMINE_API_KEY" \
       "$REDMINE_URL/projects/1/helpdesk/tickets.json"

  # Create a contact (JSON body)
  curl -sS -H "X-Redmine-API-Key: $REDMINE_API_KEY" -H "Content-Type: application/json" \
       -d '{"helpdesk_contact":{"email":"test@example.com","name":"Test"}}' \
       "$REDMINE_URL/projects/1/helpdesk/contacts.json"

  # XML also works — swap the extension
  curl -sS -H "X-Redmine-API-Key: $REDMINE_API_KEY" \
       "$REDMINE_URL/helpdesk/contacts/1.xml"
  ```

- Use a real `project_id` that has the **Helpdesk module enabled** (tickets endpoints 403
  otherwise). The acting user (owner of the key) needs the relevant permissions
  (`view_helpdesk_info`/`manage_helpdesk_contacts` for contacts, `view/add/edit/delete_issues`
  for tickets). See `API.md` for every endpoint, parameter, and expected status.
- This is host-side HTTP smoke testing. The MiniTest **integration** tests
  (`test/integration/helpdesk_api_test.rb`) still run inside the Redmine env via
  `rake redmine:plugins:test` (see above), not against localhost.

## Triggering mail fetch

No built-in scheduler. Fetch runs via the project settings button
(*Helpdesk → Fetch mails now*) or the API-key-secured global endpoint used by cron:
`curl "https://redmine.example.com/helpdesk/fetch_all?key=API-KEY"`. The `fetch_all`
cycle also piggybacks the SLA breach check and the phishing-feed sync.

## Architecture

### Plugin bootstrap (`init.rb`)
Registers the plugin, its central settings (Azure tenant/client/secret, fetch API key,
display limits, phishing feeds), the `:helpdesk` project module with its permissions, the
"Kunden" project menu, and the `HelpdeskMessage` activity provider. **Patches are prepended
directly in `init.rb`** (guarded by `unless ...include?`), *not* via `to_prepare` — the
comment there explains why: Redmine runs `init.rb` inside a `to_prepare` callback, so a
nested registration would never fire in production.

### Core: incoming mail (`lib/redmine_expert_helpdesk/`)
- **`mail_provider.rb` / `graph_provider.rb` / `imap_provider.rb`** — the mail backend
  abstraction. `MailProvider.for(mailbox)` picks the backend from `HelpdeskMailbox#provider`
  (`graph` | `imap`) and returns an object with a fixed interface (`list_messages`,
  `message_mime`, `mark_as_read`, `move_message`, folder methods, `send_mail_mime`,
  `test_connection`, `with_session`). `list_messages` returns normalized
  `MailProvider::MessageMeta` structs, so `MailProcessor` never sees provider-specific
  payloads. All provider errors derive from `MailProvider::ProviderError` — including
  `GraphClient::GraphError` — so one rescue covers both backends.
- **`imap_client.rb` / `smtp_sender.rb`** — the IMAP/SMTP backend (stdlib `net/imap`,
  `net/smtp`; no extra gem — they ship with the `mail` gem Redmine bundles). UIDs
  throughout, `BODY.PEEK` only, modified UTF-7 + server delimiter for folder names, `MOVE`
  with a `COPY`+`\Deleted`+`UID EXPUNGE` fallback. `SmtpSender` moves `Bcc` from the header
  into the envelope, which Graph/Exchange would have done for us.
- **`oauth_token_provider.rb` / `xoauth2.rb` / `mailbox_credentials.rb` / `provider_presets.rb`
  / `secret_box.rb`** — OAuth2 for IMAP/SMTP. Three grants (`client_credentials`,
  `authorization_code`, `jwt_bearer` — the last one signs its own assertion with OpenSSL, no
  `jwt` gem). Tokens are cached in `Rails.cache` under a key that fingerprints the
  credentials. `MailboxCredentials` resolves `credentials_source` (`global` | `mailbox`) —
  **one source entirely, never a field-level mix**. `SecretBox` encrypts per-mailbox secrets
  with `ActiveSupport::MessageEncryptor` (not `ActiveRecord::Encryption`, which is Rails 7+
  while we still support Redmine 5.1); values without the `enc:v1:` prefix are legacy
  plaintext and pass through. Note `net/smtp` has **no stable public XOAUTH2 API** across the
  supported Ruby range — `SmtpXoauth2` dispatches over three shapes, see the comments there.
- **`graph_client.rb`** — Microsoft Graph REST client. OAuth2 client-credentials (app-only)
  flow; token cached in the Rails cache. Lists/moves/reads messages, fetches raw MIME,
  sends mail (JSON and full-MIME variants). Needs `Mail.ReadWrite` + `Mail.Send` app permissions.
- **`mail_processor.rb`** — the heart. Per mailbox: load from source folder → black/whitelist
  → ignore rules → hand raw MIME to **Redmine's own `MailHandler`** (which does ticket
  creation, reply matching via `In-Reply-To`/`[#id]`, attachments, user creation) → apply
  new-ticket defaults → link contact → autoresponder → phishing check → attach `.eml` → move
  to target folder. Reply-vs-new-ticket matching is delegated entirely to `MailHandler`; the
  plugin only supplies MIME and reacts to the result. Returns a `Result` struct.
  `apply_new_issue_defaults` runs **for new tickets only** and in this order: the project's
  `default_assigned_to_id` (a `Principal`, so a user **or** a group — skipped when `MailHandler`
  already honoured an `Assigned to:` keyword), then the mailbox rules, which are the more
  specific statement and may override it. One `reload`, one `save(:validate => false)`.
- **`inline_images.rb`** — embedded images of incoming mail. `MailHandler` saves them as
  attachments but keeps the client's reference in the text (`[cid:…]` from Outlook,
  `[image: …]` from Gmail, `<img src="cid:…">`), so the ticket showed markers instead of
  pictures. `rewrite!` points those markers at the attachment that was just stored, in the
  image syntax of `Setting.text_formatting` (`!name.png!` vs `![](name.png)`), for the issue
  description and for journal notes alike. `prepare_mime` runs **before** `MailHandler` and only
  when Redmine builds the body from the HTML part (its HTML-to-text parser has no `img` rule, so
  the reference would vanish) — it rewrites `<img>` to the same `[cid:…]` marker and touches only
  the copy handed to `MailHandler`, never the `.eml` archived on the ticket. Unknown references
  are left in place; the plugin setting `inline_images_enabled` switches the whole thing off.
- **`init_mailer.rb`** — outbound "initial" mail when an agent assigns a contact to a ticket
  and opts to email them (also used by the "New Helpdesk Ticket" flow).
- **`mail_logger.rb`** — one log line per outgoing mail, naming the transport it took.
  **Every send site wraps its send in `MailLogger.track`** (reply controller, `init_mailer`,
  autoresponder in `mail_processor`, `info_request_mailer`, `HelpdeskSlaMailer`) — three
  transports × five senders otherwise all look identical in the log. Success uses the `mail_log_level` plugin setting
  (default `info`), failures are always `error` and the exception is re-raised.
- **`template_renderer.rb`** — `{{issue.*}}`-style Mustache-ish templating for subjects,
  headers/footers, autoresponder bodies. `RESOLVERS` feeds both the renderer and the chip
  catalogue; `CONTEXT_RESOLVERS` (currently `{{missing_info}}`) resolves from a value the caller
  passes in and is deliberately **kept out of `catalogue`**, because it is meaningless outside its
  own template and would only clutter the chip bar.
- **`ai_client.rb`** — AI provider client for per-project mail summaries. `Net::HTTP` (mirrors
  `graph_client.rb`), three providers: `openai` (Chat Completions), `anthropic` (Messages),
  `custom` (OpenAI-compatible base URL for self-hosted). Central config in the plugin settings
  (`ai_*` keys). Ships `DEFAULT_PROMPT`. Called from **`HelpdeskAiSummaryJob`**
  (`app/jobs/`, ActiveJob), which `MailProcessor#enqueue_ai_summary` fires `perform_later` after
  ingest (opt-in per project via `HelpdeskProjectSetting` `ai_summary_enabled`/`ai_summary_scope`/
  `ai_prompt_mode`/`ai_prompt`/`ai_attach_*`/`ai_include_journal`/`ai_include_private_notes`); the job builds input from the `.eml` body (or the full ticket journal) +
  selected attachments and posts a **private** journal note. Off by default; failures are logged,
  never break ingestion. Token usage is captured (`AiClient#last_usage`) and stored per note in
  **`HelpdeskAiSummary`** (`app/models/`, migration 028); the `_issue_sidebar` badge JS renders a
  🤖 token badge on that note's journal header, mirroring the to/cc/bcc recipient badges.
  Agents can re-run it on demand via **`HelpdeskAiController#regenerate`** (sidebar button,
  `send_helpdesk_reply` permission), which enqueues the job with `force: true` (bypasses the
  per-project enable/scope).
- **`completeness_check.rb` / `info_request_mailer.rb`** — completeness check of the *first* mail of
  a new ticket. `CompletenessCheck` is pure (no DB/HTTP/mail) and holds both modes: `evaluate` runs
  the per-project rule set (min chars/words, attachment required, expected terms, threshold — a `0`
  disables an individual rule) after stripping quoted history/forward headers/signatures, and
  `parse_ai_verdict` reads the model's JSON. Both return the same `Verdict`. The AI path **fails
  closed** — unparseable output, a missing `complete` field, or "incomplete" with no reasons all
  render as *complete*, so a garbled response never mails a customer. Driven by
  **`HelpdeskCompletenessJob`** (`app/jobs/`), which `MailProcessor#enqueue_completeness_check`
  fires `perform_later` for **new tickets only**; it re-checks every gate (global
  `info_request_enabled`, per-project `info_request_mode`, plus `AiFeatures.ai_enabled?` +
  `AiClient#configured?` in AI mode) before anything leaves the box. `InfoRequestMailer` sends the
  templated follow-up along the mailbox's `outgoing_route` (the autoresponder's shape, plain text —
  none of `init_mailer`'s HTML/CID machinery), threads it with `In-Reply-To`/`References`, writes a
  public journal note, and the job then records the send on `HelpdeskTicketInfo`
  (`info_request_count`) — **the repeat guard**, so a re-fetch or reopen cannot mail twice.
  AI-mode calls log as `HelpdeskAiRequest` type `completeness`. Off by default; migrations 043–044.
- **`knowledge_store.rb` / `knowledge_extractor.rb`** — RAG knowledge base from resolved tickets.
  On close (**`Issue#after_save`** in `patches/issue_patch.rb` → `saved_change_to_status_id? &&
  closed?`, so single **and** bulk/API closes are caught) or via rake
  (`redmine_expert_helpdesk:kb_backfill` / `kb_reembed`), **`HelpdeskKnowledgeIngestJob`** extracts
  `{problem, solution}` (`AiClient.summarize`), stores a `HelpdeskKnowledgeEntry` (SQL = system of
  record + curation), and — when approved — embeds the problem (`AiClient#embed`) into the vector
  store. **`KnowledgeStore.for(settings)`** picks the backend by `kb_backend`: `QdrantStore` (REST,
  no gem, collection per project) or `PgvectorStore` (`gem 'pg'`, guarded require; single table with
  a mandatory `WHERE project_id`). **Strict per-project isolation.** `HelpdeskAiSummaryJob` retrieves
  similar entries and injects a "Lösungsvorschlag" into the summary and/or writes `HelpdeskKbProposal`
  rows for the sidebar (per-project `kb_ingest_mode` / `kb_proposal_display`; `HelpdeskKnowledgeController`
  for manual approve/ingest). Off by default; failures logged, never break ingestion. Migrations 030–032.
  The **pgvector backend needs `gem 'pg'`** added in the deployment (not in `PluginGemfile`, to keep
  the default Qdrant build free of libpq).
- **`business_hours.rb` / `sla.rb` / `sla_breach_check.rb`** — SLA in *business minutes*.
  `business_hours` defines the working-day/time window; `sla` computes reaction/solution
  deadlines (with per-priority overrides via `HelpdeskSlaPriority`); `sla_breach_check`
  runs during fetch and notifies on breach.
- **`phish*.rb` / `phishing_scanner.rb`** — download PhishTank + Phishing.Database feeds into
  a local `HelpdeskPhishingUrl` mirror; scan incoming links (decoding Microsoft SafeLinks
  locally). On hit: neutralize (warn banner + journal note) or quarantine, per project.
- **`legacy_contacts_import.rb`** — one-off import from the `redmine_contacts` plugin.
- **`hooks.rb`** — `ViewListener` view hooks (customer sidebar card, ticket-header info bar,
  reply form, activity-feed CSS) and `controller_issues_*_after_save` hooks. Injected via
  Redmine view hooks, so no Deface.

### Patches (`lib/redmine_expert_helpdesk/patches/`)
`Issue`, `IssueQuery`, `Project`, `ProjectsHelper` — extend Redmine core with helpdesk
associations, query columns/filters, and helpers. Applied in `init.rb` (see above). Most are
`prepend`ed; **`ProjectsHelperPatch` and `QueriesHelperPatch` are the exceptions** — both wrap a
core helper (`project_settings_tabs` resp. `column_content`) via **UnboundMethod capture**
(`apply!` captures the current method as an `UnboundMethod`, `define_method`s a replacement that
calls the captured original explicitly), **not** prepend/super, so they coexist with
`alias_method_chain`-based plugins that patch the same methods (e.g. RedmineUP
`redmine_contacts_helpdesk`) — prepend/super collides there (`super: no superclass method`). For the
same coexistence, our project-settings tab is named **`expert_helpdesk`** (not `helpdesk`, which
RedmineUP also registers); the internal `:tab => 'expert_helpdesk'` redirects match.

**Controller and constant names must not collide with `redmine_contacts_helpdesk`.** Every
plugin's `app/` is on the same Zeitwerk autoload path, so two plugins shipping
`app/controllers/helpdesk_oauth_controller.rb` means only the first one on the path is ever
loaded — the second silently never exists, and calls against it fail with `NoMethodError`, not
with a missing-constant error. Ours is therefore **`ExpertHelpdeskOauthController`**
(`expert_helpdesk_oauth_controller.rb`, route helpers `expert_helpdesk_oauth_*`); the public
path `/helpdesk/oauth/callback` is unaffected. Before adding a file under `app/`, check
`ls ../redmine_contacts_helpdesk/app/<dir>` for the same basename. Note also that Zeitwerk
derives the constant from the filename with its default inflector, so an acronym-cased class
(`OAuthTokenProvider`) in `oauth_token_provider.rb` aborts boot — spell it `Oauth…`.

### Web layer (`app/`)
Standard Rails MVC under the plugin. Controllers map to permissions declared in `init.rb`'s
`project_module :helpdesk` block (`manage_helpdesk`, `fetch_helpdesk_mail`,
`send_helpdesk_reply`, `view_helpdesk_info`, `manage_helpdesk_contacts`). Key ones:
`helpdesk_fetch` (fetch button + `fetch_all` endpoint), `helpdesk_replies` (agent→customer
replies, largest controller — handles MIME/CID inline images/transport choice),
`helpdesk_mailboxes`, `helpdesk_contacts`, `helpdesk_init`, `helpdesk_project_settings`.

### Models (`app/models/`)
`HelpdeskMailbox` (per-project mailbox config: provider, IMAP/SMTP + OAuth2 credentials, folders, filters, reply transport),
`HelpdeskContact` (auto-saved senders, per project), `HelpdeskMessage` (in/out/init message
log with `.eml` + sent attachments, powers the activity feed), `HelpdeskRule`,
`HelpdeskProjectSetting` (reply/SLA/phishing defaults), `HelpdeskSlaPriority`,
`HelpdeskTicketInfo` (contact link + SLA tracking per issue), `HelpdeskPhishingUrl`.

### Schema (`db/migrate/`)
Sequential numbered migrations (`001_...` onward). Add the next number when changing schema;
never edit a shipped migration.

## Key behaviors worth knowing

- **Outgoing mail is per-mailbox and validated against the provider**: `provider` (default for
  new mailboxes — the mailbox's own backend: Graph, or its own SMTP server), `graph` (Graph via
  the central app registration), or `smtp` (Redmine's global SMTP, inline images become Base64
  data URIs). Both MIME paths send full Base64 MIME to preserve CID inline images — Exchange
  rewrites HTML in the JSON send path. `HelpdeskMailbox#outgoing_route` resolves `provider` to
  `graph`/`mailbox_smtp`; it is named for the route, not for replies, because replies, initial
  mails **and** the autoresponder all follow it. **Anything that sends must ask
  `MailProvider.outgoing_for(mailbox)`** — never `MailProvider.for`, which is the *receiving*
  factory; three call sites once kept their own copy of that branch and each was wrong at least
  once. `graph` is only available when `graph_transport_available?`: a Graph mailbox, or an IMAP
  mailbox whose **effective** preset is Microsoft **and** with the central app registration
  configured. Effective means `MailboxCredentials.preset_for` — the `oauth_preset` column is not in
  force for a mailbox on global credentials (blank or stale), and deciding this from the column was
  a bug. The model validates it, so a Gmail mailbox cannot be pointed at `sendMail` for an address
  that does not exist in the tenant; `syncTransport` in the mailbox form mirrors the same rule.
- **A Sent copy is filed for IMAP mailboxes** (`ImapClient#append_sent`), because SMTP files
  nothing and Graph's `sendMail` does. Folder resolution: RFC 6154 `\Sent` special-use flag →
  `sent_folder` column → preset. A failed APPEND is logged and swallowed — the customer already
  has the mail by then.
- **Every processed mail is stored as an `.eml` attachment** ("Original E-Mail") on the
  ticket; replies also get a download link at the top of the journal comment.
- **`unknown_user_mode` on the mailbox** (`accept`/`create`/`ignore`) controls handling of
  senders with no Redmine user — enforced by `MailHandler`.
- Azure app registration is a one-time external setup (README has PowerShell/Terraform/CLI
  recipes); central credentials live under *Administration → Plugins → Redmine expert Helpdesk*,
  which also holds the default IMAP/SMTP + OAuth2 credentials. The README's *Mail providers*
  section has setup recipes for Microsoft app-only IMAP, Gmail consent, and self-hosted servers.
- **OAuth consent uses one fixed callback URL** (`/helpdesk/oauth/callback`) because identity
  providers only accept exactly registered redirect URIs; the mailbox id rides in a signed
  `state` (`Rails.application.message_verifier`), never in the path.
