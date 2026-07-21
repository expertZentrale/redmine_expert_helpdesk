# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A **Redmine plugin** (`redmine_expert_helpdesk`) that turns Microsoft 365 mailboxes
into a helpdesk: incoming mail becomes tickets (or journal replies), agents reply to
customers from the ticket page, and contacts/SLA/phishing detection layer on top. Requires
Redmine 5.0+.

This plugin is developed **inside the parent `redmine-expert` deployment repo** (two levels
up, `../../`), which packages plugins, themes and Docker/Kubernetes config. **This repo is
NOT a Redmine checkout** — there is no Gemfile, `rake`, or `config/database.yml` at
`../../`. Base Redmine is supplied by a Docker image; the app only exists inside the running
container (`/usr/src/redmine`), so host-level `bundle exec rake` does not work.

Comments, i18n and much documentation are in **German**; match the surrounding language
when editing (`README.md` is EN, `README.de.md` is DE — keep both in sync for user-facing changes).

## Development workflow (Docker)

Run everything from the **parent repo root** (`../../`, i.e. `/home/buehring/GIT/redmine-expert`).

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
- **`graph_client.rb`** — Microsoft Graph REST client. OAuth2 client-credentials (app-only)
  flow; token cached in the Rails cache. Lists/moves/reads messages, fetches raw MIME,
  sends mail (JSON and full-MIME variants). Needs `Mail.ReadWrite` + `Mail.Send` app permissions.
- **`mail_processor.rb`** — the heart. Per mailbox: load from source folder → black/whitelist
  → ignore rules → hand raw MIME to **Redmine's own `MailHandler`** (which does ticket
  creation, reply matching via `In-Reply-To`/`[#id]`, attachments, user creation) → apply
  rules → link contact → autoresponder → phishing check → attach `.eml` → move to target
  folder. Reply-vs-new-ticket matching is delegated entirely to `MailHandler`; the plugin
  only supplies MIME and reacts to the result. Returns a `Result` struct.
- **`init_mailer.rb`** — outbound "initial" mail when an agent assigns a contact to a ticket
  and opts to email them (also used by the "New Helpdesk Ticket" flow).
- **`template_renderer.rb`** — `{{issue.*}}`-style Mustache-ish templating for subjects,
  headers/footers, autoresponder bodies.
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
associations, query columns/filters, and helpers. Applied in `init.rb` (see above).

### Web layer (`app/`)
Standard Rails MVC under the plugin. Controllers map to permissions declared in `init.rb`'s
`project_module :helpdesk` block (`manage_helpdesk`, `fetch_helpdesk_mail`,
`send_helpdesk_reply`, `view_helpdesk_info`, `manage_helpdesk_contacts`). Key ones:
`helpdesk_fetch` (fetch button + `fetch_all` endpoint), `helpdesk_replies` (agent→customer
replies, largest controller — handles MIME/CID inline images/transport choice),
`helpdesk_mailboxes`, `helpdesk_contacts`, `helpdesk_init`, `helpdesk_project_settings`.

### Models (`app/models/`)
`HelpdeskMailbox` (per-project O365 config + folders + filters + reply transport),
`HelpdeskContact` (auto-saved senders, per project), `HelpdeskMessage` (in/out/init message
log with `.eml` + sent attachments, powers the activity feed), `HelpdeskRule`,
`HelpdeskProjectSetting` (reply/SLA/phishing defaults), `HelpdeskSlaPriority`,
`HelpdeskTicketInfo` (contact link + SLA tracking per issue), `HelpdeskPhishingUrl`.

### Schema (`db/migrate/`)
Sequential numbered migrations (`001_...` onward). Add the next number when changing schema;
never edit a shipped migration.

## Key behaviors worth knowing

- **Reply transport is per-mailbox**: `graph` (default, sends full Base64 MIME via
  `/users/{mailbox}/sendMail` to preserve CID inline images — Exchange rewrites HTML in the
  JSON send path) or `smtp` (Redmine SMTP, inline images become Base64 data URIs).
- **Every processed mail is stored as an `.eml` attachment** ("Original E-Mail") on the
  ticket; replies also get a download link at the top of the journal comment.
- **`unknown_user_mode` on the mailbox** (`accept`/`create`/`ignore`) controls handling of
  senders with no Redmine user — enforced by `MailHandler`.
- Azure app registration is a one-time external setup (README has PowerShell/Terraform/CLI
  recipes); central credentials live under *Administration → Plugins → Redmine Expert Helpdesk*.
