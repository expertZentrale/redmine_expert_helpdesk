# GitHub Copilot instructions — redmine_expert_helpdesk

These instructions apply to the whole repository. They mirror `CLAUDE.md` (the fuller
companion doc — read it for deeper architecture notes); keep the two in sync when either changes.

## What this is

A **Redmine plugin** (`redmine_expert_helpdesk`) that turns Microsoft 365 **or IMAP** mailboxes into a
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
- **Every change must update `CHANGELOG.md` (EN, authoritative)** and its German mirror
  **`CHANGELOG.de.md`**; for user-facing changes also **`README.md` (EN) and `README.de.md` (DE)**.
  Keep each EN/DE pair in sync. GitHub release notes are generated from `CHANGELOG.md`.
- **Language policy:** write **code comments in English** (legacy German comments may remain until
  that code is next touched). **i18n stays bilingual** (`config/locales/en.yml` + `de.yml`) and the
  plugin UI is German.
- **Never edit a shipped migration.** When changing schema, add the next sequential number in
  `db/migrate/` (`001_...` onward).
- Don't hard-code secrets/API keys. Local dev credentials live in `.dev.env` (git-ignored).
- **Don't develop features on `main`.** Every feature, bugfix or schema change goes on a
  `type/short-desc` branch and reaches `main` via a squash-merged PR (see *Git workflow* below).

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

## Git workflow (feature branches)

`main` is the protected integration branch — **release tags are cut only from merged `main`**.
Do not build features directly on it.

- **Branch per unit of work**, named `type/short-desc` where `type` matches the Conventional-Commit
  style used in the CHANGELOG: `feat/…`, `fix/…`, `chore/…`, `docs/…`, `refactor/…`, `test/…`
  (e.g. `feat/sla-priority-overrides`, `fix/graph-token-refresh`). Branch off the latest `main`.
- **Commit messages** follow the same Conventional-Commit prefixes; keep commits focused and
  include the CHANGELOG/README updates the change requires (see the CHANGELOG hard rule above).
- **Open a PR** into `main`. CI (`ci.yml`, `docker-image.yml`) runs on PRs and **must pass** before
  merge. Prefer a short self-review / description linking the change to its CHANGELOG entry.
- **Squash-merge** the PR — one commit per feature keeps `main` history linear and readable. Delete
  the branch after merge.
- **Exception — trivial fixes may commit straight to `main`**: docs/typo/CHANGELOG-only tweaks that
  touch no code and no schema. Anything touching Ruby/JS, migrations, i18n or behavior needs a
  branch + PR.
- **Never rewrite published history** (`main`, or any branch someone else has pulled). Rebase only
  your own un-pushed local commits.

## Releases (tag-driven)

GitHub Releases are produced only by pushing a semver tag, never on normal pushes/PRs. The plugin
version is the **single source of truth in `init.rb`** (`version '...'`): bump + commit it, then
tag the same commit and push (`git tag vX.Y.Z && git push origin vX.Y.Z`).
`.github/workflows/release.yml` (`push: tags: v*`) **verifies** `init.rb` version == tag (fails on
mismatch), builds `redmine_expert_helpdesk-<version>.{zip,tar.gz}` (top-level
`redmine_expert_helpdesk/` dir, dev files excluded) from the tagged tree, and publishes the release
with notes from the CHANGELOG entries added since the previous tag. `ci.yml` / `docker-image.yml`
run on `main`/PRs only.

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
  - `mail_provider.rb` / `graph_provider.rb` / `imap_provider.rb` — mail backend abstraction.
    `MailProvider.for(mailbox)` picks the backend from `HelpdeskMailbox#provider` (`graph` |
    `imap`); `list_messages` returns normalized `MailProvider::MessageMeta` structs, so
    `MailProcessor` never sees provider-specific payloads. All provider errors derive from
    `MailProvider::ProviderError` — including `GraphClient::GraphError`.
  - `imap_client.rb` / `smtp_sender.rb` — IMAP/SMTP backend on stdlib `net/imap` + `net/smtp`
    (no extra gem; they ship with the `mail` gem Redmine bundles). UIDs throughout, `BODY.PEEK`
    only, modified UTF-7 + server delimiter for folder names, `MOVE` with a
    `COPY`+`\Deleted`+`UID EXPUNGE` fallback. `SmtpSender` moves `Bcc` into the envelope, which
    Graph/Exchange used to do for us. `net/smtp` has **no stable public XOAUTH2 API** across the
    supported Ruby range — `SmtpXoauth2` dispatches over three shapes.
  - `oauth_token_provider.rb` / `xoauth2.rb` / `mailbox_credentials.rb` / `provider_presets.rb` /
    `secret_box.rb` — OAuth2 for IMAP/SMTP: grants `client_credentials`, `authorization_code`,
    `jwt_bearer` (own OpenSSL-signed assertion, no `jwt` gem); tokens cached in `Rails.cache`
    under a credential-fingerprinted key. `credentials_source` (`global` | `mailbox`) selects
    **one source entirely, never a field-level mix**. `SecretBox` encrypts per-mailbox secrets
    with `ActiveSupport::MessageEncryptor` (not `ActiveRecord::Encryption` — Rails 7+, and we
    still support Redmine 5.1); values without the `enc:v1:` prefix are legacy plaintext.
  - `graph_client.rb` — Microsoft Graph REST client (OAuth2 client-credentials, token cached).
  - `mail_processor.rb` — the heart: per mailbox, hands raw MIME to Redmine's own `MailHandler`
    (which does ticket creation / reply matching via `In-Reply-To`/`[#id]` / attachments /
    user creation), then applies the new-ticket defaults, links contact, autoresponder, phishing
    check, stores `.eml`, moves the mail. Reply-vs-new matching is delegated entirely to
    `MailHandler`. `apply_new_issue_defaults` runs for new tickets only: project
    `default_assigned_to_id` (a `Principal` — user **or** group) first, mailbox rules second
    (they win); an `Assigned to:` keyword already honoured by `MailHandler` beats both.
  - `inline_images.rb` — embedded images. `MailHandler` saves them as attachments but leaves the
    client's reference in the text (`[cid:…]`, `[image: …]`, `<img src="cid:…">`), so
    `rewrite!` points those markers at the stored attachment using the image syntax of
    `Setting.text_formatting`. `prepare_mime` runs *before* `MailHandler` and only for bodies
    Redmine builds from the HTML part (its HTML-to-text parser has no `img` rule and would drop
    the reference); it edits only the copy handed to `MailHandler`, never the archived `.eml`.
    Off switch: plugin setting `inline_images_enabled`.
  - `init_mailer.rb` — outbound "initial" mail (contact-assign / "New Helpdesk Ticket" flow).
  - `mail_logger.rb` — one log line per outgoing mail incl. the transport used. Every send site
    wraps its send in `MailLogger.track` (replies, init mail, autoresponder, info request, SLA
    mail); success at
    the `mail_log_level` setting (default `info`), failures always `error` + re-raise.
  - `template_renderer.rb` — `{{issue.*}}` templating for subjects/headers/footers/autoresponder.
    `RESOLVERS` feeds renderer + chip catalogue; `CONTEXT_RESOLVERS` (`{{missing_info}}`) resolves
    from a caller-supplied value and is deliberately kept out of `catalogue`.
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
  - `completeness_check.rb` / `info_request_mailer.rb` — completeness check of the *first* mail of
    a new ticket, asking the customer for what is missing. `CompletenessCheck` is pure (no
    DB/HTTP/mail): `evaluate` runs the per-project rule set (min chars/words, attachment required,
    expected terms, threshold; `0` disables a rule) after stripping quoted history/forward
    headers/signatures, `parse_ai_verdict` reads the model's JSON — both return a `Verdict`.
    `relevant_attachments` drops images under `info_request_min_attachment_kb` (default 15 KB;
    images only, unknown size kept) so signature logos cannot satisfy "attachment required". The
    AI prompt asks for a screenshot (software) / photo (hardware), so the job appends
    `attachment_inventory` to the input — otherwise the model asks for one already attached. The AI
    path **fails closed** (unparseable output, missing `complete`, or "incomplete" with no reasons
    all count as complete), so a garbled response never mails a customer. `HelpdeskCompletenessJob`
    (`app/jobs/`) is enqueued by `MailProcessor#enqueue_completeness_check` for **new tickets only**
    and re-checks every gate (global `info_request_enabled`, per-project `info_request_mode`, plus
    `AiFeatures.ai_enabled?` + `AiClient#configured?` in AI mode). `InfoRequestMailer` sends the
    plain-text follow-up along the mailbox's `outgoing_route` (autoresponder shape), threads it via
    `In-Reply-To`/`References` and writes a journal note (public by default, internal per
    `info_request_note_visibility`). The repeat guard is `HelpdeskTicketInfo.claim_info_request!`:
    guard + increment in one row lock, claimed BEFORE the send so racing jobs cannot both mail; a
    failed send keeps the claim on purpose (at-most-once). AI calls log as `HelpdeskAiRequest`
    type `completeness`. Off by default; migrations 043-046.
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
  **File basenames under `app/` must not collide with `redmine_contacts_helpdesk` either** — every
  plugin shares one Zeitwerk autoload path, so a duplicate `app/controllers/x_controller.rb` means
  only the first on the path loads and the other silently never exists (`NoMethodError`, not a
  missing-constant error). Hence `ExpertHelpdeskOauthController` /
  `expert_helpdesk_oauth_controller.rb` / route helpers `expert_helpdesk_oauth_*`; the public path
  `/helpdesk/oauth/callback` is unchanged. Zeitwerk also derives constants with its default
  inflector — `oauth_token_provider.rb` must define `OauthTokenProvider`, not `OAuthTokenProvider`.
- **`app/`** — standard Rails MVC. Controllers map to permissions in `init.rb`'s
  `project_module :helpdesk` block. Key: `helpdesk_fetch`, `helpdesk_replies` (largest —
  MIME / CID inline images / transport choice), `helpdesk_mailboxes`, `helpdesk_contacts`,
  `helpdesk_init`, `helpdesk_project_settings`.
- **`app/models/`** — `HelpdeskMailbox`, `HelpdeskContact`, `HelpdeskMessage` (in/out/init log +
  `.eml`, powers the activity feed), `HelpdeskRule`, `HelpdeskProjectSetting`,
  `HelpdeskSlaPriority`, `HelpdeskTicketInfo`, `HelpdeskPhishingUrl`.

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
  mailbox whose **effective** preset is Microsoft (`MailboxCredentials.preset_for`, not the
  `oauth_preset` column — that one is not in force for global credentials) **and** with the central
  app registration configured. The model validates it, so a Gmail mailbox cannot be pointed at
  `sendMail` for an address that does not exist in the tenant; `syncTransport` in the mailbox form
  mirrors the same rule.
- **A Sent copy is filed for IMAP mailboxes** (`ImapClient#append_sent`), because SMTP files
  nothing and Graph's `sendMail` does. Folder resolution: RFC 6154 `\Sent` special-use flag →
  `sent_folder` column → preset. A failed APPEND is logged and swallowed — the customer already
  has the mail by then.
- **Redmine version DOM differs**: RM5 journals use `#journal-<id>-notes` / `h4.note-header`;
  RM6/7 use `#change-<id>` / `h4.journal-header` (with `span.journal-info` + `span.journal-meta`).
  View-hook JS that touches journals must handle both.
- Every processed mail is stored as an `.eml` attachment ("Original E-Mail") on the ticket.
- `unknown_user_mode` on the mailbox (`accept`/`create`/`ignore`) controls senders with no
  Redmine user, enforced by `MailHandler`.
- Azure app registration is a one-time external setup; central credentials live under
  *Administration → Plugins → Redmine expert Helpdesk*, which also holds the default IMAP/SMTP
  + OAuth2 credentials. The README's *Mail providers* section has setup recipes for Microsoft
  app-only IMAP, Gmail consent, and self-hosted servers.
- **OAuth consent uses one fixed callback URL** (`/helpdesk/oauth/callback`) because identity
  providers only accept exactly registered redirect URIs; the mailbox id rides in a signed
  `state` (`Rails.application.message_verifier`), never in the path.
